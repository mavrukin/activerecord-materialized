# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    module DependencyTrackable
      extend T::Sig

      TRACKABLE_FLAG = :@ar_materialized_dependency_trackable

      class << self
        extend T::Sig

        sig { params(model_class: T.class_of(::ActiveRecord::Base)).void }
        def subscribe(model_class)
          return if model_class.instance_variable_get(TRACKABLE_FLAG)

          install_callbacks!(model_class)
          model_class.instance_variable_set(TRACKABLE_FLAG, true)
        end

        sig { void }
        def reset!
          nil
        end

        private

        sig { params(model_class: T.class_of(::ActiveRecord::Base)).void }
        def install_callbacks!(model_class)
          T.unsafe(Kernel).eval(callback_installation_source, T.unsafe(binding), __FILE__, __LINE__)
        end

        sig { returns(String) }
        def callback_installation_source
          <<~RUBY
            model_class.class_eval do
              after_create_commit do
                DependencyRegistry.publish_write_change!(WriteChange.from_record(self, :create))
              end

              after_update_commit do
                DependencyRegistry.publish_write_change!(WriteChange.from_record(self, :update))
              end

              after_destroy_commit do
                DependencyRegistry.publish_write_change!(WriteChange.from_record(self, :destroy))
              end
            end
          RUBY
        end
      end
    end
  end
end
