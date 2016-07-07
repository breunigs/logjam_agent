require 'logjam_agent'

module LogjamAgent

  module Rack
    autoload :Logger, 'logjam_agent/rack/logger'
  end
  autoload :Middleware, 'logjam_agent/middleware'

  class Railtie < Rails::Railtie
    def logjam_log_path(app)
      paths = app.config.paths
      (Rails::VERSION::STRING < "3.1" ? paths.log.to_a : paths['log']).first.to_s
    end

    initializer "initialize_logjam_agent_logger", :before => :initialize_logger do |app|
      Rails.logger ||= app.config.logger ||
        begin
          path = logjam_log_path(app)
          logger = LogjamAgent::BufferedLogger.new(path)
          logger.level = ::Logger.const_get(app.config.log_level.to_s.upcase)
          LogjamAgent.log_device_log_level = logger.level
          logger.formatter = LogjamAgent::SyslogLikeFormatter.new
          logger.auto_flushing = false if Rails.env.production? && Rails::VERSION::STRING < "3.2"
          logger = ActiveSupport::TaggedLogging.new(logger) if Rails::VERSION::STRING >= "3.2"
          LogjamAgent.logger = logger
          logger
        rescue StandardError
          logger = LogjamAgent::BufferedLogger.new(STDERR)
          logger = ActiveSupport::TaggedLogging.new(logger) if Rails::VERSION::STRING >= "3.2"
          LogjamAgent.logger = logger
          logger.level = ::Logger::WARN
          logger.warn(
                      "Logging Error: Unable to access log file. Please ensure that #{path} exists and is writable. " +
                      "The log level has been raised to WARN and the output directed to STDERR until the problem is fixed."
                      )
          logger
        end
      if Rails::VERSION::STRING < "3.2"
        at_exit { Rails.logger.flush if Rails.logger.respond_to?(:flush) }
      end
    end

    initializer "logjam_agent", :after => "time_bandits" do |app|
      LogjamAgent.environment_name = Rails.env
      LogjamAgent.auto_detect_logged_exceptions

      app.config.middleware.swap(TimeBandits::Rack::Logger, LogjamAgent::Rack::Logger)
      app.config.middleware.insert_before(LogjamAgent::Rack::Logger, LogjamAgent::Middleware)

      if defined?(::ActionDispatch::RemoteIp)
        app.config.middleware.delete ::ActionDispatch::RemoteIp
        app.config.middleware.insert_before LogjamAgent::Middleware, ::ActionDispatch::RemoteIp, app.config.action_dispatch.ip_spoofing_check, app.config.action_dispatch.trusted_proxies
      else
        require 'logjam_agent/actionpack/lib/action_dispatch/middleware/remote_ip'
        app.config.middleware.insert_before LogjamAgent::Middleware, LogjamAgent::ActionDispatch::RemoteIp
      end

      # install a default error handler for forwarding errors
      log_dir = File.dirname(logjam_log_path(app))
      begin
        forwarding_error_logger = ::Logger.new("#{log_dir}/logjam_agent_error.log")
      rescue StandardError
        forwarding_error_logger = ::Logger.new(STDERR)
      end
      forwarding_error_logger.level = ::Logger::ERROR
      forwarding_error_logger.formatter = ::Logger::Formatter.new
      LogjamAgent.forwarding_error_logger = forwarding_error_logger

      # ignore asset requests in development
      LogjamAgent.ignore_asset_requests = Rails.env.development?

      LogjamAgent.application_revision = `git rev-parse HEAD 2>/dev/null`.chomp rescue ""

      # disable logjam request forwarding by default in test environment
      LogjamAgent.disable! if Rails.env.test?

      # patch controller testing to create a logjam request, because middlewares aren't executed
      if Rails.env.test?
        ActiveSupport.on_load(:action_controller) do
          module TestWithLogjamStartRequest
            def process(*args)
              LogjamAgent.start_request
              super
            ensure
              LogjamAgent.finish_request
            end
          end
          require 'action_controller/test_case'
          ActionController::TestCase::Behavior.prepend TestWithLogjamStartRequest
        end
      end
    end

    # avoid garbled tempfile information in the logs
    ActiveSupport.on_load(:action_controller) do
      ActionDispatch::Http::UploadedFile.class_eval <<-"EVA"
        def to_hash
          {
            :original_filename => original_filename,
            :content_type => content_type,
            :headers => headers,
            :tempfile => { :path => tempfile.path },
            :size => size
          }
        end
      EVA
    end

    if Rails::VERSION::STRING >= "5.0"
      # we want our exceptions logged as a single string
      # TODO: actually, when logging with tags, we might want to have tags and timestamps,
      # but only on disk. Not sure how useful this would be.
      ActiveSupport.on_load(:action_controller) do
        ActionDispatch::DebugExceptions.class_eval do
          def log_error(request, wrapper)
            logger = logger(request)
            return unless logger

            exception = wrapper.exception

            trace = wrapper.application_trace
            trace = wrapper.framework_trace if trace.empty?

            ActiveSupport::Deprecation.silence do
              parts = [ "#{exception.class} (#{exception.message})" ]
              parts.concact exception.annoted_source_code if exception.respond_to?(:annoted_source_code)
              parts.concat trace
              logger.fatal parts.join("\n  ")
            end
          end
        end
      end
    end

    config.after_initialize do
      if LogjamAgent.ignore_render_events
        ActiveSupport::Notifications.unsubscribe("render_template.action_view")
        ActiveSupport::Notifications.unsubscribe("render_partial.action_view")
        ActiveSupport::Notifications.unsubscribe("render_collection.action_view")
      end
    end
  end
end
