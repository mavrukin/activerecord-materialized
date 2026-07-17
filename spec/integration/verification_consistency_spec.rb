# frozen_string_literal: true

require_relative "integration_helper"

# Marker module so RSpec/DescribeClass and the spec-file-path convention are met.
module VerificationConsistency; end

# #94 — DataVerifier reads the cache and the recomputed source inside one transaction, so both
# sides come from a single snapshot. A write landing between the two reads (or, when reads are
# pinned to a replica, replication lag) then can't make consistent data look like drift. Runs on
# MySQL and Postgres (real MVCC snapshots); SQLite is single-writer (skipped).
RSpec.describe VerificationConsistency, :db_matrix do
  IntegrationAdapters.candidates.each do |profile|
    context "with #{profile.label}" do
      before do
        skip("SQLite is single-writer — no cross-connection snapshot to exercise") if profile.key == :sqlite
        with_adapter!(profile)
      end

      it "does not report false drift when a committed write lands mid-verify" do
        view = IntegrationSchema.define_view("mv_verify_consistency")
        IntegrationSchema.bulk_seed_line_items(10)
        view.rebuild!(confirm: true) # cache == source

        interleave_write_once(view, category: "late-arrival")
        result = ActiveRecord::Materialized::DataVerifier.new(view, mode: :full).verify

        # Without the consistent snapshot the source read would see "late-arrival" (a partition the
        # cache lacks) and report false drift; inside one snapshot both reads predate that write.
        expect(result.drifted?).to be(false)
      end

      it "verifies inside an already-open transaction without raising (isolation downgrade)" do
        view = IntegrationSchema.define_view("mv_verify_nested")
        IntegrationSchema.bulk_seed_line_items(5)
        view.rebuild!(confirm: true)

        # A nested transaction can't raise its isolation level, so verify must fall back to a plain
        # (savepoint) transaction rather than raising ActiveRecord::TransactionIsolationError.
        expect do
          view.transaction { ActiveRecord::Materialized::DataVerifier.new(view, mode: :full).verify }
        end.not_to raise_error
      end

      # Commit a brand-new partition from a separate connection the first time verify reads the
      # source inside its transaction — i.e. after its snapshot is fixed by the cache read.
      def interleave_write_once(view, category:)
        interleaved = false
        allow(view).to receive(:resolved_source).and_wrap_original do |original|
          if view.connection.open_transactions.positive? && !interleaved
            interleaved = true
            Thread.new do
              ActiveRecord::Base.connection_pool.with_connection do
                IntegrationSchema::LineItem.create!(category: category, sku: "x", amount: 1)
              end
            end.join
          end
          original.call
        end
      end
    end
  end
end
