require 'forwardable'
require 'inflecto'
require 'pathway/version'
require 'pathway/initializer'
require 'pathway/result'
require 'pathway/error'

module Pathway
  class Operation
    def self.plugin(name)
      require "pathway/plugins/#{Inflecto.underscore(name)}" if name.is_a?(Symbol)

      plugin = name.is_a?(Module) ? name : Plugins.const_get(Inflecto.camelize(name))

      self.extend plugin::ClassMethods if plugin.const_defined? :ClassMethods
      self.include plugin::InstanceMethods if plugin.const_defined? :InstanceMethods
      plugin.apply(self) if plugin.respond_to?(:apply)
    end
  end

  module Plugins
    module Scope
      module ClassMethods
        def scope(*attrs)
          include Initializer[*attrs]
        end
      end

      module InstanceMethods
        def initialize(*)
        end

        def context
          @context || {}
        end
      end
    end

    module Flow
      module ClassMethods
        attr_accessor :result_key

        def process(&bl)
          define_method(:call) do |input|
            DSL.new(self, input).run(&bl)
              .then { |state| state[result_key] }
          end
        end

        alias :result_at :result_key=

        def inherited(subclass)
          super
          subclass.result_key = result_key
        end
      end

      module InstanceMethods
        extend Forwardable

        def result_key
          self.class.result_key
        end

        def call(*)
          fail "must implement at subclass"
        end

        delegate %i[result success failure] => Result

        alias :wrap :result

        def error(type, message: nil, details: nil)
          failure Error.new(type: type, message: message, details: details)
        end

        def wrap_if_present(value, type: :not_found, message: nil, details: [])
          value.nil? ? error(type, message: message, details: details) : success(value)
        end
      end

      def self.apply(klass)
        klass.result_key = :value
      end

      class DSL
        def initialize(operation, input)
          @result = wrap(State.new(operation, input: input))
          @operation = operation
        end

        def run(&bl)
          instance_eval(&bl)
          @result
        end

        # Execute step and preserve the former state
        def step(callable)
          bl = _callable(callable)

          @result = @result.tee { |state| bl.call(state) }
        end

        # Execute step and modify the former state setting the key
        def set(to = nil, callable = nil)
          to, callable = @operation.result_key, to unless callable
          bl = _callable(callable)

          @result = @result.then do |state|
            wrap(bl.call(state))
              .then { |value| state.update(to => value) }
          end
        end

        # Execute step and replace the current state completely
        def map(callable)
          bl = _callable(callable)
          @result = @result.then(bl)
        end

        def sequence(with_seq, &bl)
          @result.then do |state|
            seq = -> { @result = dup.run(&bl) }
            _callable(with_seq).call(seq, state)
          end
        end

        private

        def wrap(obj)
          Result.result(obj)
        end

        def _callable(callable)
          case callable
          when Proc
            -> *args { @operation.instance_exec(*args, &callable) }
          when Symbol
            -> *args { @operation.send(callable, *args) }
          else
            callable
          end
        end
      end

      class State
        extend Forwardable

        def initialize(operation, values = {})
          @hash = operation.context.merge(values)
          @result_key = operation.result_key
        end

        delegate %i([] []= fetch store include?) => :@hash

        def update(kargs)
          @hash.update(kargs)
          self
        end

        def result
          @hash[@result_key]
        end

        def to_hash
          @hash
        end

        alias :to_h :to_hash
      end
    end
  end

  Operation.plugin Plugins::Scope
  Operation.plugin Plugins::Flow
end
