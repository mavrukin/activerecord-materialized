# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Installs `after_*_commit` callbacks on `depends_on` models so their writes schedule maintenance.
    #
    # @api private
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

        # Invoked from the model commit callbacks; `record` is the committed instance.
        # Publishes as the `:callbacks` source so views fed by another change source
        # are not maintained twice.
        sig { params(record: ::ActiveRecord::Base, operation: WriteChange::Operation).void }
        def publish(record, operation)
          DependencyRegistry.publish_write_change!(WriteChange.from_record(record, operation), source: :callbacks)
        end

        sig { void }
        def reset!
          nil
        end

        private

        sig { params(model_class: T.class_of(::ActiveRecord::Base)).void }
        def install_callbacks!(model_class)
          model = T.unsafe(model_class)
          model.after_create_commit { DependencyTrackable.publish(T.unsafe(self), :create) }
          model.after_update_commit { DependencyTrackable.publish(T.unsafe(self), :update) }
          model.after_destroy_commit { DependencyTrackable.publish(T.unsafe(self), :destroy) }
        end
      end
    end
  end
end
