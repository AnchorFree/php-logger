module Fluent
    class NamedPipeInput < Input
        Plugin.register_input('namedpipe',self)

        unless method_defined?(:log)
            define_method(:log) { $log }
        end

        def initialize
            super
            @path = nil
        end

        config_param :path, :string
        config_param :tag , :string
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
        end

        def configure_parser(conf)
            @parser = TextParser.new
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

        def parse_line(line)
            return @parser.parse(line)
        end

        def start
            super
            @pipe = open(@path,"r")
            @finished = false
            @thread = Thread.new(&method(:run))
        end

        def run
            until @finished
                begin
                    lines = @pipe.gets
                    if lines.nil?
                        sleep @receive_interval
                        next
                    end

                    lines = lines.split("\n")
                    lines.each { |line| 
                        time, record = parse_line(line)
                        if time && record
                            Engine.emit(@tag,time,record)
                        else
                            log.warn "Pattern not match: #{line.inspect}"
                        end
                    }
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
            @pipe.close
        end
    end
end
