# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class Metadata
      # Writes a view's reconciliation bookkeeping — +last_reconciled_at+ and
      # +reconciled_partition_count+ — on the metadata row. Kept out of {Metadata}
      # itself the way {MaintenancePayload} is; reads go through the metadata record.
      #
      # @api private
      module Reconciliation
        module_function

        # Stamp a completed reconciliation pass, resetting the staleness clock even
        # when no partition needed repair.
        def mark!(metadata, repaired_partition_count:)
          metadata.record.update!(
            last_reconciled_at: Timestamps.current,
            reconciled_partition_count: repaired_partition_count
          )
        end
      end
    end
  end
end
