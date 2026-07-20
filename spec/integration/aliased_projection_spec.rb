# frozen_string_literal: true

require_relative "integration_helper"

# Marker module so RSpec/DescribeClass and the spec-file-path convention are met.
module AliasedProjection; end

# #89 — a projection over an aliased Arel table must type against the underlying real table on every
# engine (the alias is unwrapped for the schema lookup). Runs the real inference — the per-engine
# connection.columns() path — against a decimal column, where the fix (scale 2) is distinguishable
# from the old unresolved fallback (scale 0). The date/integer variants are covered by the SQLite
# unit spec; the unwrap itself is engine-agnostic.
RSpec.describe AliasedProjection, :db_matrix do
  IntegrationAdapters.candidates.each do |profile|
    context "with #{profile.label}" do
      before { with_adapter!(profile) }

      after { ActiveRecord::Base.connection.drop_table(:arm_alias_probe, if_exists: true) }

      it "types an aliased-table SUM from the underlying decimal column, not the scale-0 fallback" do
        connection = ActiveRecord::Base.connection
        connection.create_table(:arm_alias_probe, force: true) do |t|
          t.string :grp
          t.decimal :amount, precision: 10, scale: 2
        end
        probe = Class.new(ActiveRecord::Base) { self.table_name = "arm_alias_probe" }
        aliased = probe.arel_table.alias("p2") # alias — not a real relation name
        relation = probe.from(aliased).group(aliased[:grp]).select(aliased[:amount].sum.as("amount_sum"))

        columns = ActiveRecord::Materialized::CacheTableSchema.column_definitions(connection, relation).index_by(&:name)

        # Resolved against arm_alias_probe, the SUM carries the source scale (2); unresolved it was 0.
        expect([columns["amount_sum"].type, columns["amount_sum"].scale]).to eq([:decimal, 2])
      end
    end
  end
end
