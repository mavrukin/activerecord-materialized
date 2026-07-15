# frozen_string_literal: true

require_relative "integration_helper"
require_relative "support/concurrent_workload"

# Marker module so RSpec/DescribeClass and the spec-file-path convention are met.
module Concurrency; end

# #84 — the less-idealized concurrency scenario. Writer processes mutate a
# scoped-recompute view via callbacks while reader processes query it AND the parent
# rebuilds it (atomic swaps) mid-flight. Proves: no writer or reader errors under real
# cross-process concurrency (readers never hit a torn/missing table — the #81
# atomic-swap guarantee), and the idempotent scoped path converges after the storm.
#
# Runs on MySQL only. It forks worker processes, and PostgreSQL's libpq is not
# fork-safe (a forked child segfaults) while MySQL's trilogy tolerates it. PostgreSQL's
# single-process behavior is fully covered by load_bearing_spec + cdc_matrix_spec; a
# spawn-based worker (fresh process, no inherited libpq state) could add PG concurrency
# as a follow-up. SQLite's in-process :memory: DB can't be shared across processes.
RSpec.describe Concurrency, :db_matrix do
  IntegrationAdapters.candidates.each do |profile|
    context "with #{profile.label}" do
      before do
        skip("SQLite's in-process :memory: database can't be shared across processes") if profile.key == :sqlite
        skip("PostgreSQL libpq is not fork-safe; fork-based concurrency runs on MySQL") if profile.key == :postgres
        with_adapter!(profile)
      end

      it "keeps concurrent writers, readers, and rebuilds correct and convergent" do
        view = IntegrationSchema.define_scoped_view("mv_concurrent")
        IntegrationSchema.bulk_seed_line_items(200) # baseline so the cache is never legitimately empty
        view.rebuild!(confirm: true)

        writer = ->(worker, i) { IntegrationSchema::LineItem.create!(category: "cat-#{i % 5}", sku: "s#{worker}", amount: i + 1) }
        result = BenchmarkSupport::ConcurrentWorkload.new(
          view: view, config: profile.connection_config, write: writer
        ).run

        expect(result.all_ok?).to be(true)    # no writer error; no torn/missing read mid-swap (#81)
        expect(result.converged?).to be(true) # idempotent scoped maintenance converged to the source
      end
    end
  end
end
