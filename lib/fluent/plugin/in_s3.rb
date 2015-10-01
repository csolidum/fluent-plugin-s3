module Fluent
  require 'fluent/mixin/config_placeholders'

  class S3Input < Input
    Fluent::Plugin.register_input('s3', self)

    def initialize
      super
      require 'aws-sdk-resources'
      require 'zlib'
      require 'time'
      require 'tempfile'

      @extractor = nil
    end

    config_param :use_server_side_encryption, :string, :default => nil
    config_param :aws_key_id, :string, :default => nil, :secret => true
    config_param :aws_sec_key, :string, :default => nil, :secret => true
    config_section :assume_role_credentials, :multi => false do
      config_param :role_arn, :string
      config_param :role_session_name, :string
      config_param :policy, :string, :default => nil
      config_param :duration_seconds, :integer, :default => nil
      config_param :external_id, :string, :default => nil
    end
    config_section :instance_profile_credentials, :multi => false do
      config_param :retries, :integer, :default => nil
      config_param :ip_address, :string, :default => nil
      config_param :port, :integer, :default => nil
      config_param :http_open_timeout, :float, :default => nil
      config_param :http_read_timeout, :float, :default => nil
      # config_param :delay, :integer or :proc, :default => nil
      # config_param :http_degub_output, :io, :default => nil
    end
    config_section :shared_credentials, :multi => false do
      config_param :path, :string, :default => nil
      config_param :profile_name, :string, :default => nil
    end
    config_param :s3_bucket, :string
    config_param :s3_region, :string, :default => ENV["AWS_REGION"] || "us-east-1"
    config_param :store_as, :string, :default => "gzip"
    config_param :check_apikey_on_start, :bool, :default => true
    config_param :proxy_uri, :string, :default => nil
    config_param :format, :string, :default => 'none'

    config_section :sqs, :multi => false do
      config_param :queue_name, :string, :default => nil
      config_param :skip_delete, :bool, :default => false
      config_param :wait_time_seconds, :integer, :default => 20
    end

    config_param :tag, :string, :default => "input.s3"

    attr_reader :bucket

    def configure(conf)
      super

      unless @sqs.queue_name
        raise ConfigError, "sqs_queue_name is required"
      end

      begin
        @extractor = EXTRACTOR_REGISTRY.lookup(@store_as).new(log: log)
      rescue
        $log.warn "#{@store_as} not found. Use 'text' instead"
        @extractor = TextExtractor.new(log: log)
      end
      @extractor.configure(conf)

      @parser = Plugin.new_parser(@format)
      @parser.configure(conf)
    end

    def start
      super

      sqs_client = create_sqs_client
      response = sqs_client.get_queue_url(queue_name: @sqs.queue_name)
      sqs_queue_url = response.queue_url

      @poller = Aws::SQS::QueuePoller.new(sqs_queue_url, client: sqs_client)

      s3_client = create_s3_client
      @s3 = Aws::S3::Resource.new(:client => s3_client)
      @bucket = @s3.bucket(@s3_bucket)

      raise "#{@bucket.name} is not found." unless @bucket.exists?

      check_apikeys if @check_apikey_on_start

      @running = true
      @thread = Thread.new(&method(:run))
    end

    def shutdown
      @running = false
      @thread.join
      super
    end

    private

    def run
      options = {}
      options[:wait_time_seconds] = @sqs.wait_time_seconds
      options[:skip_delete] = @sqs.skip_delete
      @poller.before_request do |stats|
        throw :stop_polling unless @running
      end
      @poller.poll(options) do |message|
        begin
          body = Yajl.load(message.body)
          next unless body["Records"] # skip test queue

          process(body)
        rescue => e
          log.warn "#{e.message}\n#{e.backtrace.join("\n")}"
          @running = false
          throw :skip_delete
        end
      end
    end

    def setup_credentials
      options = {}
      credentials_options = {}
      case
      when @aws_key_id && @aws_sec_key
        options[:access_key_id] = @aws_key_id
        options[:secret_access_key] = @aws_sec_key
      when @assume_role_credentials
        c = @assume_role_credentials
        credentials_options[:role_arn] = c.role_arn
        credentials_options[:role_session_name] = c.role_session_name
        credentials_options[:policy] = c.policy if c.policy
        credentials_options[:duration_seconds] = c.duration_seconds if c.duration_seconds
        credentials_options[:external_id] = c.external_id if c.external_id
        options[:credentials] = Aws::AssumeRoleCredentials.new(credentials_options)
      when @instance_profile_credentials
        c = @instance_profile_credentials
        credentials_options[:retries] = c.retries if c.retries
        credentials_options[:ip_address] = c.ip_address if c.ip_address
        credentials_options[:port] = c.port if c.port
        credentials_options[:http_open_timeout] = c.http_open_timeout if c.http_open_timeout
        credentials_options[:http_read_timeout] = c.http_read_timeout if c.http_read_timeout
        options[:credentials] = Aws::InstanceProfileCredentials.new(credentials_options)
      when @shared_credentials
        c = @shared_credentials
        credentials_options[:path] = c.path if c.path
        credentials_options[:profile_name] = c.profile_name if c.profile_name
        options[:credentials] = Aws::SharedCredentials.new(credentials_options)
      else
        # Use default credentials
        # See http://docs.aws.amazon.com/sdkforruby/api/Aws/S3/Client.html
      end
      options
    end

    def create_s3_client
      options = setup_credentials
      options[:region] = @s3_region if @s3_region
      options[:proxy_uri] = @proxy_uri if @proxy_uri
      options[:s3_server_side_encryption] = @use_server_side_encryption.to_sym if @use_server_side_encryption

      Aws::S3::Client.new(options)
    end

    def create_sqs_client
      options = setup_credentials
      options[:region] = @s3_region if @s3_region

      Aws::SQS::Client.new(options)
    end

    def check_apikeys
      @bucket.objects.first
    rescue => e
      raise "can't call S3 API. Please check your aws_key_id / aws_sec_key or s3_region configuration. error = #{e.inspect}"
    end

    def process(body)
      s3 = body["Records"].first["s3"]
      key = s3["object"]["key"]

      io = @bucket.object(key).get.body
      content = @extractor.extract(io)
      content.each_line do |line|
        time, record = @parser.parse(line)
        router.emit(@tag, time, record)
      end
    end

    class Extractor
      include Configurable

      attr_reader :log

      def initialize(log: $log, **options)
        super()
        @log = log
      end

      def configure(conf)
        super
      end

      def ext
      end

      def content_type
      end

      def extract(io)
      end

      private

      def check_command(command, algo = nil)
        require 'open3'

        algo = command if algo.nil?
        begin
          Open3.capture3("#{command} -V")
        rescue Errno::ENOENT
          raise ConfigError, "'#{command}' utility must be in PATH for #{algo} compression"
        end
      end
    end

    class GzipExtractor < Extractor
      def ext
        'gz'.freeze
      end

      def content_type
        'application/x-gzip'.freeze
      end

      def extract(io)
        Zlib::GzipReader.wrap(io) do |gz|
          gz.read
        end
      end
    end

    class TextExtractor < Extractor
      def ext
        'txt'.freeze
      end

      def content_type
        'text/plain'.freeze
      end

      def extract(io)
        io.read
      end
    end

    class JsonExtractor < TextExtractor
      def ext
        'json'.freeze
      end

      def content_type
        'application/json'.freeze
      end
    end

    EXTRACTOR_REGISTRY = Registry.new(:s3_extractor_type, 'fluent/plugin/s3_extractor_')
    {
      'gzip' => GzipExtractor,
      'text' => TextExtractor,
      'json' => JsonExtractor
    }.each do |name, extractor|
      EXTRACTOR_REGISTRY.register(name, extractor)
    end

    def self.register_extractor(name, extractor)
      EXTRACTOR_REGISTRY.register(name, extractor)
    end
  end
end
