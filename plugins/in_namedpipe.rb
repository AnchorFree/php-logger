require 'fluent/input'
require 'fluent/config/error'
require 'fluent/event'

module Fluent
    class NamedPipeInput < Input
        Plugin.register_input('pipe',self)

        unless method_defined?(:log)
            define_method(:log) { $log }
        end

        # To support Fluentd v0.10.57 or earlier
        unless method_defined?(:router)
            define_method("router") { Fluent::Engine }
        end

        def initialize
            super
            @path = nil
        end

        config_param :path, :string
        config_param :tag , :string
        desc 'The interval of flushing the buffer for multiline format'
        config_param :multiline_flush_interval, :time, default: nil
        #TODO: Not use yet
        config_param :receive_interval, :time, :default => 1

        def configure(conf)
            super

            if !File.exists?(@path)
                raise ConfigError,"File not found #{@path}"
            end

            if @tag.nil? 
                raise ConfigError,"tag is empty"
            end

            configure_parser(conf)

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

        #TODO: Not yet used
        def configure_tag
            if @tag.index('*')
                @tag_prefix, @tag_suffix = @tag.split('*')
                @tag_suffix ||= ''
            else
                @tag_prefix = nil
                @tag_suffix = nil
            end

        end

        def start
            super
            @finished = false
            @thread = Thread.new(&method(:run))
        end

        def run
            @line_buffer_timer_flusher = (@multiline_mode && @multiline_flush_interval) ? true : nil
            @log.trace "opening pipe: ", @path
            @pipe = open(@path,"r")
            @log.trace "opened pipe: ", @pipe
            @pw = PipeWatcher.new(@log, @multiline_flush_interval, @parser)

            Thread.new do
                @pw.timer()
            end

            until @finished
                begin
                    lines = @pipe.gets
                    if lines.nil?
                        @log.trace "nothing to read, sleeping"
                        sleep @receive_interval
                        next
                    end
                    @log.trace "reading lines"

                    lines = lines.split("\n")
                    receive_lines(lines, @pw)
                rescue
                    log.error "unexpected error", :error=>$!.to_s
                    log.error_backtrace
                end
            end
        end

        def shutdown
            super
            @finished = true
            @thread.join
            @pw.finished = true
            @pipe.close
        end

        # @return true if no error or unrecoverable error happens in emit action. false if got BufferQueueLimitError
        def receive_lines(lines, pw)
            @log.trace "entered receive_lines"
            es = @receive_handler.call(lines, pw)
            unless es.empty?
                tag = if @tag_prefix || @tag_suffix
                          @tag_prefix + @tag_suffix
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

        def convert_line_to_event(line, es)
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
                        es.add(time, record)
                    else
                        if @emit_unmatched_lines
                            record = {'unmatched_line' => line}
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

        def parse_singleline(lines, pw)
            @log.trace "enetered parse_singleline"
            es = MultiEventStream.new
            lines.each { |line|
                convert_line_to_event(line, es)
            }
            es
        end

        def parse_multilines(lines, pw)
            @log.trace "enetered parse_multilines"
            lb = pw.line_buffer
            @log.trace "pw line buffer before manipulations is :  ", pw.line_buffer
            es = MultiEventStream.new
            @start = @pw.start
            if @parser.has_firstline?
                if @line_buffer_timer_flusher
                    @pw.notify(@tag)
                    @log.trace "started timer at: ", @pw.start
                end
                lines.each { |line|
                    @log.trace "parsing line: ", line
                    if @parser.firstline?(line)
                        @log.trace "this matched first line template"
                        if lb
                            @log.trace "converting line to event stream"
                            convert_line_to_event(lb, es)
                        end
                        @log.trace "assigning line to line buffer"
                        lb = line
                    else
                        if lb.nil?
                            if @emit_unmatched_lines
                                convert_line_to_event(line, es)
                            end
                            log.warn "got incomplete line before first line from #{path}: #{line.inspect}"
                        else
                            lb << line
                        end
                    end
                }
            else

                log.warn "went to else"
                lb ||= ''
                lines.each do |line|
                    lb << line
                    @parser.parse(lb) { |time, record|
                        if time && record
                            convert_line_to_event(lb, es)
                            lb = ''
                        end
                    }
                end
            end
            @pw.line_buffer = lb
            log.trace "pw line buffer after manipulations is :  ", @pw.line_buffer
            es
        end


        class PipeWatcher

            def initialize(log, flush_interval, parser)
                @start = nil
                @log = log
                @flush_interval = flush_interval
                @parser = parser
                @tag = nil
                @finished = finished
            end

            attr_accessor :line_buffer
            attr_accessor :start
            attr_accessor :finished

            def notify(tag)
                @log.trace "entered notify"
                @tag = tag
                @start = Time.now()
            end

            def timer()
                @log.trace "entered timer"
                until @finished
                    @log.trace "do something in timer loop ", @start, " flush interval: ", @flush_interval 
                    if @start && @flush_interval
                        @log.trace "Check to fush buffer"
                        if Time.now - start >= @flush_interval
                            @log.trace "need to flush  buffer"
                            flush_buffer()
                            line_buffer = nil
                            @start = nil
                            @log.trace "buffr flushed"
                        end
                    end
                    if @flush_interval
                        sleep @flush_interval
                    else
                        sleep 2
                    end

                end
            end

            def flush_buffer()
                @log.trace "entered flush_buffer"
                if lb = @line_buffer
                    @log.trace "lb = line_buffer"
                    lb.chomp!
                    if @encoding
                        if @from_encoding
                            lb.encode!(@encoding, @from_encoding)
                        else
                            lb.force_encoding(@encoding)
                        end
                    end
                    @log.trace "pre parser pase lb: ", lb
                    @parser.parse(lb) { |time, record|

                        @log.trace "time: ", time, " record: ", record
                        if time && record
                            tag = if @tag_prefix || @tag_suffix
                                      @tag_prefix + @tag_suffix
                                  else
                                      @tag
                                  end
                            @log.trace "tag: ", tag
                            Engine.emit(@tag,time,record)
                            #router.emit(tag, time, record)
                            @log.trace "submitted events"
                        else
                            log.warn "got incomplete line at shutdown from #{path}: #{lb.inspect}"
                        end
                    }
                end
            end

        end # PipeWatcher
    end # NamedPipeInput
end # Fluent
