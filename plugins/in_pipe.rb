require 'cool.io'

require 'fluent/input'
require 'fluent/config/error'
require 'fluent/event'

module Fluent
  class NewNamedPipeInput < Input
    Plugin.register_input('pipe', self)

    def initialize
      super
      @paths = []
      @tails = {}
    end

    desc 'The paths to read. Multiple paths can be specified, separated by comma.'
    config_param :path, :string
    desc 'The tag of the event.'
    config_param :tag, :string
    desc 'Receive interval'
    config_param :receive_interval, :time, :default => 1
    desc 'The paths to exclude the files from watcher list.'
    config_param :exclude_path, :array, default: []
    desc 'The interval of refreshing the list of watch file.'
    config_param :refresh_interval, :time, default: 60
    desc 'The number of reading lines at each IO.'
    config_param :read_lines_limit, :integer, default: 1000
    desc 'The interval of flushing the buffer for multiline format'
    config_param :multiline_flush_interval, :time, default: nil
    desc 'Enable the option to emit unmatched lines.'
    config_param :emit_unmatched_lines, :bool, default: false
    desc 'Enable the additional watch timer.'
    config_param :enable_watch_timer, :bool, default: true
    desc 'The encoding after conversion of the input.'
    config_param :encoding, :string, default: nil
    desc 'The encoding of the input.'
    config_param :from_encoding, :string, default: nil
    desc 'Add the log path being tailed to records. Specify the field name to be used.'
    config_param :path_key, :string, default: nil
    desc 'Limit the watching files that the modification time is within the specified time range (when use \'*\' in path).'
    config_param :limit_recently_modified, :time, default: nil
    desc 'Enable the option to skip the refresh of watching list on startup.'
    config_param :skip_refresh_on_startup, :bool, default: false

    attr_reader :paths

    def configure(conf)
      super

      @paths = @path.split(',').map {|path| path.strip }
      if @paths.empty?
        raise ConfigError, "tail: 'path' parameter is required on tail input"
      end

      configure_parser(conf)
      configure_tag
      configure_encoding

      @multiline_mode = conf['format'] =~ /multiline/
      @receive_handler = if @multiline_mode
                           method(:parse_multilines)
                         else
                           method(:parse_singleline)
                         end
    end

    def configure_parser(conf)
      @parser = Plugin.new_parser(conf['format'])
      @parser.configure(conf)
    end

    def configure_tag
      if @tag.index('*')
        @tag_prefix, @tag_suffix = @tag.split('*')
        @tag_suffix ||= ''
      else
        @tag_prefix = nil
        @tag_suffix = nil
      end
    end

    def configure_encoding
      unless @encoding
        if @from_encoding
          raise ConfigError, "tail: 'from_encoding' parameter must be specified with 'encoding' parameter."
        end
      end

      @encoding = parse_encoding_param(@encoding) if @encoding
      @from_encoding = parse_encoding_param(@from_encoding) if @from_encoding
    end

    def parse_encoding_param(encoding_name)
      begin
        Encoding.find(encoding_name) if encoding_name
      rescue ArgumentError => e
        raise ConfigError, e.message
      end
    end

    def start
      @log.trace "entered start"
      @finished = false
      @loop = Coolio::Loop.new
      refresh_watchers unless @skip_refresh_on_startup

      @refresh_trigger = TailWatcher::TimerWatcher.new(@refresh_interval, true, log, &method(:refresh_watchers))
      @refresh_trigger.attach(@loop)
      @thread = Thread.new(&method(:run))
    end

    def shutdown
      @log.trace "entered shutdown"
      @refresh_trigger.detach if @refresh_trigger && @refresh_trigger.attached?

      stop_watchers(@tails.keys, true)
      @loop.stop rescue nil # when all watchers are detached, `stop` raises RuntimeError. We can ignore this exception.
      @thread.join
      @pf_file.close if @pf_file
    end

    def expand_paths
      @log.trace "entered expand_paths"
      date = Time.now
      paths = []

      excluded = @exclude_path.map { |path| path = date.strftime(path); path.include?('*') ? Dir.glob(path) : path }.flatten.uniq
      @paths.each { |path|
        path = date.strftime(path)
        if path.include?('*')
          paths += Dir.glob(path).select { |p|
            is_file = !File.directory?(p)
            if File.readable?(p) && is_file
              if @limit_recently_modified && File.mtime(p) < (date - @limit_recently_modified)
                false
              else
                true
              end
            else
              if is_file
                log.warn "#{p} unreadable. It is excluded and would be examined next time."
              end
              false
            end
          }
        else
          # When file is not created yet, Dir.glob returns an empty array. So just add when path is static.
          paths << path
        end
      }
      paths - excluded
    end

    # in_tail with '*' path doesn't check rotation file equality at refresh phase.
    # So you should not use '*' path when your logs will be rotated by another tool.
    # It will cause log duplication after updated watch files.
    # In such case, you should separate log directory and specify two paths in path parameter.
    # e.g. path /path/to/dir/*,/path/to/rotated_logs/target_file
    def refresh_watchers
      @log.trace "entered refresh_watchers"
      target_paths = expand_paths
      existence_paths = @tails.keys

      unwatched = existence_paths - target_paths
      added = target_paths - existence_paths

      stop_watchers(unwatched, false, true) unless unwatched.empty?
      start_watchers(added) unless added.empty?
    end

    def setup_watcher(path)
      @log.trace "entered setup_watchers"
      line_buffer_timer_flusher = (@multiline_mode && @multiline_flush_interval) ? TailWatcher::LineBufferTimerFlusher.new(log, @multiline_flush_interval, &method(:flush_buffer)) : nil
      tw = TailWatcher.new(path, log, @enable_watch_timer, @read_lines_limit, method(:update_watcher), line_buffer_timer_flusher,  &method(:receive_lines))
      tw.attach(@loop)
      tw
    end

    def start_watchers(paths)
      @log.trace "entered start_watchers"
      paths.each { |path|
        @tails[path] = setup_watcher(path)
      }
    end

    def stop_watchers(paths, immediate = false, unwatched = false)
      @log.trace "entered stop_watchers"
      paths.each { |path|
        tw = @tails.delete(path)
        if tw
          tw.unwatched = unwatched
          if immediate
            close_watcher(tw, false)
          else
            close_watcher_after_rotate_wait(tw)
          end
        end
      }
    end

    # refresh_watchers calls @tails.keys so we don't use stop_watcher -> start_watcher sequence for safety.
    def update_watcher(path)
      @log.trace "entered update_watchers"
      rotated_tw = @tails[path]
      @tails[path] = setup_watcher(path)
      close_watcher_after_rotate_wait(rotated_tw) if rotated_tw
    end

    # TailWatcher#close is called by another thread at shutdown phase.
    # It causes 'can't modify string; temporarily locked' error in IOHandler
    # so adding close_io argument to avoid this problem.
    # At shutdown, IOHandler's io will be released automatically after detached the event loop
    def close_watcher(tw, close_io = true)
      @log.trace "entered close_watchers"
      tw.close(close_io)
      flush_buffer(tw)
      if tw.unwatched && @pf
        @pf[tw.path].update_pos(PositionFile::UNWATCHED_POSITION)
      end
    end

    def close_watcher_after_rotate_wait(tw)
      @log.trace "entered close_watcher_after_rotate_wait"
      closer = TailWatcher::Closer.new(tw, log, &method(:close_watcher))
      closer.attach(@loop)
    end

    def flush_buffer(tw)
      @log.trace "entered flush_buffer"
      if lb = tw.line_buffer
        lb.chomp!
        if @encoding
          if @from_encoding
            lb.encode!(@encoding, @from_encoding)
          else
            lb.force_encoding(@encoding)
          end
        end
        @parser.parse(lb) { |time, record|
          if time && record
            tag = if @tag_prefix || @tag_suffix
                    @tag_prefix + tw.tag + @tag_suffix
                  else
                    @tag
                  end
            record[@path_key] ||= tw.path unless @path_key.nil?
            router.emit(tag, time, record)
          else
            log.warn "got incomplete line at shutdown from #{tw.path}: #{lb.inspect}"
          end
        }
      end
    end

    def run
      @log.trace "entered run"
      @loop.run
    rescue
      log.error "unexpected error", error: $!.to_s
      log.error_backtrace
    end

    # @return true if no error or unrecoverable error happens in emit action. false if got BufferQueueLimitError
    def receive_lines(lines, tail_watcher)
      @log.trace "entered receive_lines"
      es = @receive_handler.call(lines, tail_watcher)
      unless es.empty?
        tag = if @tag_prefix || @tag_suffix
                @tag_prefix + tail_watcher.tag + @tag_suffix
              else
                @tag
              end
        begin
          router.emit_stream(tag, es)
        rescue BufferQueueLimitError
          return false
        rescue
          # ignore non BufferQueueLimitError errors because in_tail can't recover. Engine shows logs and backtraces.
          return true
        end
      end

      return true
    end

    def convert_line_to_event(line, es, tail_watcher)
      @log.trace "enetered convert_line_to_event"
      begin
        line.chomp!  # remove \n
        if @encoding
          if @from_encoding
            line.encode!(@encoding, @from_encoding)
          else
            line.force_encoding(@encoding)
          end
        end
        @parser.parse(line) { |time, record|
          if time && record
            record[@path_key] ||= tail_watcher.path unless @path_key.nil?
            es.add(time, record)
          else
            if @emit_unmatched_lines
              record = {'unmatched_line' => line}
              record[@path_key] ||= tail_watcher.path unless @path_key.nil?
              es.add(::Fluent::Engine.now, record)
            end
            log.warn "pattern not match: #{line.inspect}"
          end
        }
      rescue => e
        log.warn line.dump, error: e.to_s
        log.debug_backtrace(e.backtrace)
      end
    end

    def parse_singleline(lines, tail_watcher)
      @log.trace "enetered parse_singleline"
      es = MultiEventStream.new
      lines.each { |line|
        convert_line_to_event(line, es, tail_watcher)
      }
      es
    end

    def parse_multilines(lines, tail_watcher)
      @log.trace "enetered parse_multilines"
      lb = tail_watcher.line_buffer
      es = MultiEventStream.new
      if @parser.has_firstline?
        tail_watcher.line_buffer_timer_flusher.reset_timer if tail_watcher.line_buffer_timer_flusher
        lines.each { |line|
          if @parser.firstline?(line)
            if lb
              convert_line_to_event(lb, es, tail_watcher)
            end
            lb = line
          else
            if lb.nil?
              if @emit_unmatched_lines
                convert_line_to_event(line, es, tail_watcher)
              end
              log.warn "got incomplete line before first line from #{tail_watcher.path}: #{line.inspect}"
            else
              lb << line
            end
          end
        }
      else
        lb ||= ''
        lines.each do |line|
          lb << line
          @parser.parse(lb) { |time, record|
            if time && record
              convert_line_to_event(lb, es, tail_watcher)
              lb = ''
            end
          }
        end
      end
      tail_watcher.line_buffer = lb
      es
    end

    class TailWatcher
      def initialize(path, log, enable_watch_timer, read_lines_limit, update_watcher, line_buffer_timer_flusher, &receive_lines)
        @log = log
        @log.trace "enetered TailWatcher::initialize"
        @path = path
        @enable_watch_timer = enable_watch_timer
        @read_lines_limit = read_lines_limit
        @receive_lines = receive_lines
        @update_watcher = update_watcher

        @timer_trigger = TimerWatcher.new(1, true, log, &method(:on_notify)) if @enable_watch_timer

        @rotate_handler = RotateHandler.new(path, log, &method(:on_rotate))
        @io_handler = nil

        @line_buffer_timer_flusher = line_buffer_timer_flusher
      end

      attr_reader :path
      attr_accessor :line_buffer, :line_buffer_timer_flusher
      attr_accessor :unwatched  # This is used for removing position entry from PositionFile

      def tag
        @log.trace "enetered TailWatcher::tag"
        @parsed_tag ||= @path.tr('/', '.').gsub(/\.+/, '.').gsub(/^\./, '')
      end

      def wrap_receive_lines(lines)
        @log.trace "enetered TailWatcher::wrap_receive_lines"
        @receive_lines.call(lines, self)
      end

      def attach(loop)
        @log.trace "enetered TailWatcher::attach"
        @timer_trigger.attach(loop) if @enable_watch_timer
        on_notify
      end

      def detach
        @log.trace "enetered TailWatcher::detach"
        @timer_trigger.detach if @enable_watch_timer && @timer_trigger.attached?
      end

      def close(close_io = true)
        @log.trace "enetered TailWatcher::close"
        if close_io && @io_handler
          @io_handler.on_notify
          @io_handler.close
        end
        detach
      end

      def on_notify
        @log.trace "enetered TailWatcher::on_notify"
        @rotate_handler.on_notify if @rotate_handler
        @line_buffer_timer_flusher.on_notify(self) if @line_buffer_timer_flusher
        return unless @io_handler
        @io_handler.on_notify
      end

      def on_rotate(io)
        @log.trace "enetered TailWatcher::on_rotate"
        if @io_handler == nil
          if io
            # first time
            stat = io.stat
            inode = stat.ino

            @io_handler = IOHandler.new(io, @log, @read_lines_limit, &method(:wrap_receive_lines))
          else
            @io_handler = NullIOHandler.new
          end
        else
          @log.info log_msg

          if io
            stat = io.stat
            inode = stat.ino
              io_handler = IOHandler.new(io, @log, @read_lines_limit, &method(:wrap_receive_lines))
              @io_handler = io_handler
          else # file is rotated and new file not found
            # Clear RotateHandler to avoid duplicated file watch in same path.
            @rotate_handler = nil
            @update_watcher.call(@path)
          end
        end

      end

      class TimerWatcher < Coolio::TimerWatcher
        def initialize(interval, repeat, log, &callback)
          @log = log
          @log.trace "enetered TimerWatcher::initialize"
          @callback = callback
          super(interval, repeat)
        end

        def on_timer
          @log.trace "enetered TimerWatcher::on_timer"
          @callback.call
        rescue
          # TODO log?
          @log.error $!.to_s
          @log.error_backtrace
        end
      end

      class Closer < Coolio::TimerWatcher
        def initialize(interval, tw, log, &callback)
          @log.trace "enetered Closer::initialize"
          @callback = callback
          @tw = tw
          @log = log
          super(interval, false)
        end

        def on_timer
          @log.trace "enetered Closer::on_timer"
          @callback.call(@tw)
        rescue => e
          @log.error e.to_s
          @log.error_backtrace(e.backtrace)
        ensure
          detach
        end
      end

      class IOHandler
        def initialize(io, log, read_lines_limit, first = true, &receive_lines)
          @log = log
          @log.trace "enetered IOHandler::initialize"
          @log.info "following tail of #{io.path}" if first
          @io = io
          @read_lines_limit = read_lines_limit
          @receive_lines = receive_lines
          @buffer = ''.force_encoding('ASCII-8BIT')
          @iobuf = ''.force_encoding('ASCII-8BIT')
          @lines = []
        end

        attr_reader :io

        def on_notify
          @log.trace "enetered IOHandler::on_notify"
          begin
            read_more = false

            if @lines.empty?
              @log.trace "lines are empty"
              begin
                while true
                  if @buffer.empty?
                    @log.trace "enetered IOHandler::on_notify::bufer is empty"
                    @io.readpartial(2048, @buffer)
                  else
                    @log.trace "enetered IOHandler::on_notify:: reading from buffer"
                    @buffer << @io.readpartial(2048, @iobuf)
                  end
                  while idx = @buffer.index("\n".freeze)
                      @lines << @buffer.slice!(0, idx + 1)
                      if @lines.size >= @read_lines_limit
                          # not to use too much memory in case the file is very large
                          @log.trace "enetered IOHandler::on_notify:: need to wait for lines tobe processed"
                          read_more = true
                          break
                      end
                      unless @lines.empty?
                          @log.trace "enetered IOHandler::on_notify:: sending lines to receive_lines"
                          if @receive_lines.call(@lines)
                              @log.trace "enetered IOHandler::on_notify:: clearing lines"
                              @lines.clear
                          else
                              break
                          end
                      end
                  end
                end
              rescue EOFError
              end
            end

            unless @lines.empty?
                @log.trace "enetered IOHandler::on_notify:: sending lines to receive_lines"
                if @receive_lines.call(@lines)
                    @log.trace "enetered IOHandler::on_notify:: clearing lines"
                    @lines.clear
                else
                    read_more = false
                end
            end

          end while read_more

        rescue
          @log.error $!.to_s
          @log.error_backtrace
          close
        end

        def close
          @io.close unless @io.closed?
        end
      end

      class NullIOHandler
        def initialize
        end

        def io
        end

        def on_notify
        end

        def close
        end
      end

      class RotateHandler
        def initialize(path, log, &on_rotate)
          @path = path
          @inode = nil
          @fsize = -1  # first
          @on_rotate = on_rotate
          @log = log
        end

        def on_notify
          begin
            stat = File.stat(@path)
            inode = stat.ino
            fsize = stat.size
          rescue Errno::ENOENT
            # moved or deleted
            inode = nil
            fsize = 0
          end

          begin
            if @inode != inode || fsize < @fsize
              # rotated or truncated
              begin
                io = open(@path, "r")
              rescue Errno::ENOENT
              end
              @on_rotate.call(io)
            end
            @inode = inode
            @fsize = fsize
          end

        rescue
          @log.error $!.to_s
          @log.error_backtrace
        end
      end


      class LineBufferTimerFlusher
        def initialize(log, flush_interval, &flush_method)
          @log = log
          @flush_interval = flush_interval
          @flush_method = flush_method
          @start = nil
        end

        def on_notify(tw)
          if @start && @flush_interval
            if Time.now - @start >= @flush_interval
              @flush_method.call(tw)
              tw.line_buffer = nil
              @start = nil
            end
          end
        end

        def reset_timer
          @start = Time.now
        end
      end
    end



  end
end
