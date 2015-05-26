module IRuby
  class Kernel
    RED = "\e[31m"
    WHITE = "\e[37m"
    RESET = "\e[0m"

    class<< self
      attr_accessor :instance
    end

    attr_reader :session, :comms

    def initialize(config_file)
      @config = MultiJson.load(File.read(config_file))
      IRuby.logger.debug("IRuby kernel start with config #{@config}")
      Kernel.instance = self

      @session = Session.new(@config)
      $stdout = OStream.new(@session, 'stdout')
      $stderr = OStream.new(@session, 'stderr')

      @execution_count = 0
      @backend = create_backend
      @running = true
      @comms = {}
    end

    def create_backend
      PryBackend.new
    rescue Exception => ex
      IRuby.logger.warn ex.message unless LoadError === ex
      PlainBackend.new
    end

    def run
      send_status('starting')
      while @running
        ident, msg = @session.recv(:reply)
        type = msg[:header]['msg_type']
        if type =~ /comm_|_request\Z/ && respond_to?(type)
          send_status('busy')
          send(type, ident, msg)
          send_status('idle')
        else
          IRuby.logger.error "Unknown message type: #{msg[:header]['msg_type']} #{msg.inspect}"
        end
      end
    end

    def kernel_info_request(ident, msg)
      content = {
        protocol_version: '5.0',
        implementation: 'iruby',
        implementation_version: IRuby::VERSION,
        language_info: {
          name: 'ruby',
          version: RUBY_VERSION,
          mimetype: 'text/ruby',
          file_extension: 'rb',
        },
        banner: "IRuby #{IRuby::VERSION}"
      }
      @session.send(:reply, 'kernel_info_reply', content, ident)
    end

    def send_status(status)
      @session.send(:publish, 'status', {execution_state: status})
    end

    def execute_request(ident, msg)
      begin
        code = msg[:content]['code']
      rescue
        IRuby.logger.fatal "Got bad message: #{msg.inspect}"
        return
      end

      @execution_count += 1 if msg[:content]['store_history']
      @session.send(:publish, 'execute_input', {code: code, execution_count: @execution_count}, ident)

      result = nil
      begin
        result = @backend.eval(code, msg[:content]['store_history'])
        content = {
          status: 'ok',
          payload: [],
          user_expressions: {},
          execution_count: @execution_count
        }
      rescue SystemExit
        raise
      rescue Exception => e
        content = {
          status: 'error',
          ename: e.class.to_s,
          evalue: e.message,
          traceback: ["#{RED}#{e.class}#{RESET}: #{e.message}", *e.backtrace.map { |l| "#{WHITE}#{l}#{RESET}" }],
          execution_count: @execution_count
        }
        @session.send(:publish, 'error', content, ident)
      end
      @session.send(:reply, 'execute_reply', content, ident)
      unless result.nil? || msg[:content]['silent']
        @session.send(:publish, 'execute_result', data: Display.display(result), metadata: {}, execution_count: @execution_count)
      end
    end

    def complete_request(ident, msg)
      content = {
        matches: @backend.complete(msg[:content]['code']),
        status: 'ok',
        cursor_start: 0,
        cursor_end: msg[:content]['cursor_pos']
      }
      @session.send(:reply, 'complete_reply', content, ident)
    end

    def connect_request(ident, msg)
      @session.send(:reply, 'connect_reply', Hash[%w(shell_port iopub_port stdin_port hb_port).map {|k| [k, @config[k]] }], ident)
    end

    def shutdown_request(ident, msg)
      @session.send(:reply, 'shutdown_reply', msg[:content], ident)
      @running = false
    end

    def history_request(ident, msg)
      # we will just send back empty history for now, pending clarification
      # as requested in ipython/ipython#3806
      content = {
        history: []
      }
      @session.send(:reply, 'history_reply', content, ident)
    end

    def inspect_request(ident, msg)
      o = @backend.eval(msg[:content]['oname'])
      content = {
        oname: msg[:content]['oname'],
        found: true,
        ismagic: false,
        isalias: false,
        docstring: '', # TODO
        type_class: o.class.superclass.to_s,
        string_form: o.inspect
      }
      content[:length] = o.length if o.respond_to?(:length)
      @session.send(:reply, 'inspect_reply', content, ident)
    rescue Exception
      content = {
        oname: msg[:content]['oname'],
        found: false
      }
      @session.send(:reply, 'inspect_reply', content, ident)
    end

    def comm_open(ident, msg)
      comm_id = msg[:content]['comm_id']
      target_name = msg[:content]['target_name']
      target = Comm.targets[target_name]
      @comms[comm_id] = target.new(target_name, comm_id)
    end

    def comm_msg(ident, msg)
      @comms[msg[:content]['comm_id']].comm_msg(msg[:content]['data'])
    end

    def comm_close(ident, msg)
      comm_id = msg[:content]['comm_id']
      @comms[comm_id].comm_close
      @comms.delete(comm_id)
    end
  end
end
