# frozen_string_literal: true

require_relative "integration_helper"

# Marker module so RSpec/DescribeClass and the spec-file-path convention are met.
module IndexPreservation; end

# #128 / #144 — the atomic swap must preserve cache-table indexes across a full rebuild. The freshly
# built temp table only carries the schema-default partition-key index, so any other index (a
# user-added one) would be lost with the dropped old table unless TableSwap re-creates it. This
# correctness depends on each engine's rename semantics — a transaction on SQLite/Postgres, a single
# RENAME TABLE on MySQL/MariaDB (whose DDL auto-commits) — so it is exercised on the real-DB matrix,
# not just the SQLite unit spec in relation_cache_writer_spec.
RSpec.describe IndexPreservation, :db_matrix do
  IntegrationAdapters.candidates.each do |profile|
    context "with #{profile.label}" do
      before { with_adapter!(profile) }

      def index_signatures(table)
        ActiveRecord::Base.connection.indexes(table).map { |index| [index.columns.sort, index.unique] }
      end

      it "keeps a user-added index across rebuild! and does not duplicate the default one" do
        view = IntegrationSchema.define_view("mv_index_preservation")
        seed_line_items(["books", 10], ["games", 20])
        view.rebuild!(confirm: true)
        ActiveRecord::Base.connection.add_index("mv_index_preservation", :total_amount,
                                                name: "idx_preservation_total")

        view.rebuild!(confirm: true) # full atomic swap: build temp, rename in, drop old

        # both the default unique partition-key index and the user index survive, neither duplicated
        expect(index_signatures("mv_index_preservation"))
          .to contain_exactly([["category"], true], [["total_amount"], false])
      end
    end
  end
end
