# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Installs `after_*_commit` callbacks on `depends_on` models so their writes schedule maintenance.
    #
    # @api private
    module DependencyTrackable
      TRACKABLE_FLAG = :@ar_materialized_dependency_trackable

      class << self
        def subscribe(model_class)
          return if model_class.instance_variable_get(TRACKABLE_FLAG)

          install_callbacks!(model_class)
          model_class.instance_variable_set(TRACKABLE_FLAG, true)
        end

        # Invoked from the model commit callbacks; `record` is the committed instance.
        # Publishes as the `:callbacks` source so views fed by another change source
        # are not maintained twice.
        def publish(record, operation)
          DependencyRegistry.publish_write_change!(WriteChange.from_record(record, operation), source: :callbacks)
        end

        def reset!
          nil
        end

        private

        def install_callbacks!(model_class)
          model = model_class
          model.after_create_commit { DependencyTrackable.publish(self, :create) }
          model.after_update_commit { DependencyTrackable.publish(self, :update) }
          model.after_destroy_commit { DependencyTrackable.publish(self, :destroy) }
        end
      end
    end
  end
end
