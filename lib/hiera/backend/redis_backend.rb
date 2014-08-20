class Hiera
  module Backend
    class Redis_backend

      VERSION='1.0.4'

      attr_reader :redis, :options


      def initialize
        require 'redis'
        Hiera.debug("Hiera Redis backend %s starting" % VERSION)
        @redis = connect
        if @redis.nil?
          raise "Unable to create connection to redis - check debug output for problems errors"
        end
      rescue LoadError
        Hiera.debug("Hiera Redis backend couldn't find 'redis'")
        retry if require 'rubygems'
        Hiera.warn("Couldn't load redis gem")
        raise
      end


      def deserialize(args = {})
        return nil if args[:data].nil?
        return args[:data] unless args[:data].is_a? String

        result = case options[:deserialize]
        when :json
          require 'json'
          JSON.parse args[:data]
        when :yaml
          require 'yaml'
          YAML::load args[:data]
        else
          Hiera.warn "Invalid configuration for :deserialize; found %s" % options[:deserialize]
          args[:data]
        end

        Hiera.debug "Deserialized %s" % options[:deserialize].to_s.upcase
        result
      # when we try to deserialize a string
      rescue JSON::ParserError
        args[:data]
      rescue => e
        Hiera.warn "Exception raised: %s: %s" % [e.class, e.message]
      end


      def lookup(key, scope, order_override, resolution_type)
        answer = nil

        Backend.datasources(scope, order_override) do |source|
          redis_key = "%s" % [source.split('/'), key].join(options[:separator])
          Hiera.debug "Looking for %s%s%s" % [source, options[:separator], key]

          data = redis_query redis_key

          data = deserialize(:data => data,
                  :redis_key => redis_key,
                  :key => key) if options.include? :deserialize

          next unless data

          new_answer = Backend.parse_answer(data, scope)

          case resolution_type
          when :array
            raise Exception, "Hiera type mismatch: expected Array and got #{new_answer.class}" unless new_answer.is_a? Array or new_answer.is_a? String
            answer ||= []
            answer << new_answer
          when :hash
            raise Exception, "Hiera type mismatch: expected Hash and got #{new_answer.class}" unless new_answer.is_a? Hash
            answer ||= {}
            answer = Backend.merge_answer(new_answer,answer)
          else
            answer = new_answer
            break
          end
        end

        answer
      end


      private


      def connect
        # override default options
        @options = {
          :host => 'localhost',
          :port => 6379,
          :db => 0,
          :password => nil,
          :timeout => 3,
          :path => nil,
          :soft_connection_failure => false,
          :separator => ':'
        }.merge Config[:redis] || {}

        Redis.new(options)
      end


      def redis_query(redis_key)
        case redis.type redis_key
        when 'set'
          redis.smembers redis_key
        when 'hash'
          redis.hgetall redis_key
        when 'list'
          redis.lrange(redis_key, 0, -1)
        when 'string'
          redis.get redis_key
        when 'zset'
          redis.zrange(redis_key, 0, -1)
        else
          Hiera.debug("No such key: %s" % redis_key)
          nil
        end
      rescue Redis::CannotConnectError => e
        Hiera.warn('Cannot connect to Redis server')
        raise e unless options.has_key?(:soft_connection_failure)
        nil
      end

    end
  end
end
