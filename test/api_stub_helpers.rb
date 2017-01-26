require "json"

# Provides a set of helpers for a test suite that help to mock out the Stripe
# API.
module APIStubHelpers
  protected

  # Uses Webmock to stub out the Stripe API for testing purposes. The stub will
  # by default respond on any routes that are defined in the bundled
  # hyper-schema with generated response data.
  #
  # An `override_app` can be specified to get finer grain control over how a
  # stubbed endpoint responds. It can be used to modify generated responses,
  # mock expectations, or even to override the default stub completely.
  def stub_api(override_app = nil, &block)
    if block
      override_app = Sinatra.new(OverrideSinatra, &block)
    elsif !override_app
      override_app = @@default_override_app
    end

    stub_request(:any, /^#{Stripe.api_base}/).to_rack(new_api_stub(override_app))
  end

  def stub_connect
    stub_request(:any, /^#{Stripe.connect_base}/).to_return(:body => "{}")
  end

  private

  class APIStubMiddleware
    API_FIXTURES = APIFixtures.new
    LIST_PROPERTIES = Set.new(["has_more", "data", "url"]).freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      schema = env["committee.response_schema"]
      resource_id = schema.data["x-resourceId"] || ""
      if data = API_FIXTURES[resource_id.to_sym]
        env["committee.response"] = data
      else
        if LIST_PROPERTIES.subset?(Set.new(schema.properties.keys))
          resource_id = schema.properties["data"].items.data["x-resourceId"] || ""
          if data = API_FIXTURES[resource_id.to_sym]
            env["committee.response"]["data"] = [data]
          else
            raise "no suitable fixture for list resource: #{resource_id}"
          end
        else
          raise "no fixture for: #{resource_id}"
        end
      end
      @app.call(env)
    end
  end

  # A descendant of the standard `Sinatra::Base` with some added helpers to
  # make working with generated responses more convenient.
  class OverrideSinatra < Sinatra::Base
    # A simple hash-like class that doesn't allow any keys to be accessed or
    # defined that were not present on its initialization.
    #
    # Its secondary function is allowing indifferent access regardless of
    # whether a string or symbol is used as a key.
    #
    # The purpose of the class is to make modifying API responses safer by
    # disallowing the setting of keys that were not in the original response.
    class TempermentalHash
      # Initializes a TempermentalHash from a standard Hash. Note that
      # initialization is performed recursively so any hashes included as
      # values of the top-level hash will also be concerted.
      def initialize(hash)
        @hash = hash.dup
        @hash.each do |k, v|
          @hash[k] = TempermentalHash.new(v) if v.is_a?(Hash)
        end
      end

      def [](key)
        get(key)
      end

      def []=(key, val)
        set(key, val)
      end

      def deep_merge!(hash, options = {})
        hash.each do |k, v|
          if v.is_a?(Hash)
            if !@hash[k].is_a?(Hash)
              unless options[:allow_undefined_keys]
                raise ArgumentError, "'#{k}' in stub response is not a hash " +
                  "and cannot be deep merged"
              end
            end
            val = self.get(
               k,
              :allow_undefined_keys => options[:allow_undefined_keys]
            )

            if val
              val.deep_merge!(v)
            else
              self.set(
                k, v,
                :allow_undefined_keys => options[:allow_undefined_keys]
              )
            end
          else
            self.set(
              k, v,
              :allow_undefined_keys => options[:allow_undefined_keys]
            )
          end
        end
      end

      def get(key, options = {})
        key = key.to_s
        check_key!(key) unless options[:allow_undefined_keys]
        @hash[key]
      end

      def set(key, val, options = {})
        key = key.to_s
        check_key!(key) unless options[:allow_undefined_keys]
        @hash[key] = val
      end

      def to_h
        h = {}
        @hash.each do |k, v|
          h[k] = v.is_a?(TempermentalHash) ? v.to_h : v
        end
        h
      end

      private

      def check_key!(key)
        unless @hash.key?(key)
          raise ArgumentError, "'#{key}' is not defined in stub response"
        end
      end
    end

    def modify_generated_response
      safe_hash = TempermentalHash.new(env["committee.response"])
      yield(safe_hash)
      env["committee.response"] = safe_hash.to_h
    end

    # The hash of data generated based on OpenAPI spec information for the
    # requested route of the API.
    #
    # It's also worth nothing that this could be `nil` in the event of the
    # spec not knowing how to respond to the requested route.
    def generated_response
      env["committee.response"]
    end

    # This instructs the response stubbing framework that it should *not*
    # respond with a generated response on this request. Instead, control is
    # wholly given over to the override method.
    def override_response!
      env["committee.suppress"] = true
    end

    not_found do
      "endpoint not found in API stub: #{request.request_method} #{request.path_info}"
    end
  end

  # Finds the latest OpenAPI specification in ROOT/spec/ and parses it for
  # use with Committee.
  def self.initialize_spec
    schema_data = ::JSON.parse(File.read("#{PROJECT_ROOT}/spec/spec.json"))

    driver = Committee::Drivers::OpenAPI2.new
    driver.parse(schema_data)
  end

  # Creates a new Rack app with Committee middleware wrapping an internal app.
  def new_api_stub(override_app)
    Rack::Builder.new {
      use Committee::Middleware::RequestValidation, schema: @@spec,
        params_response: true, strict: true
      use Committee::Middleware::Stub, schema: @@spec,
        call: true
      use APIStubMiddleware
      run override_app
    }
  end

  # Parse and initialize the hyper-schema only once for the entire test suite.
  @@spec = initialize_spec

  # The default override app. Doesn't respond on any route so generated
  # responses will always take precedence.
  @@default_override_app = Sinatra.new
end
