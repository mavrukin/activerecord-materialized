# frozen_string_literal: true

require_relative "integration_helper"
require_relative "support/concurrent_workload"

# Marker module so RSpec/DescribeClass and the spec-file-path convention are met.
module Concurrency; end

# #84 — the less-idealized concurrency scenario. Separate spawned worker processes
# mutate a scoped-recompute view via callbacks while other workers query it AND the
# parent rebuilds it (atomic swaps) mid-flight. Proves the safety property under real
# cross-process concurrency: no worker crashes, writers' rows are durable, readers
# never see a torn/empty cache (the #81 atomic-swap guarantee), and the system
# re-converges. Runs on MySQL and Postgres — workers are spawned (not forked), so each
# opens its own clean connection (libpq is not fork-safe). SQLite is skipped: its
# in-process :memory: database isn't shared across separate processes.
RSpec.describe Concurrency, :db_matrix do
  IntegrationAdapters.candidates.each do |profile|
    context "with #{profile.label}" do
      before do
        skip("SQLite's in-process :memory: database isn't shared across separate processes") if profile.key == :sqlite
        with_adapter!(profile)
      end

      it "keeps concurrent writers, readers, and rebuilds correct and convergent" do
        view = IntegrationSchema.define_scoped_view("mv_concurrent")
        IntegrationSchema.bulk_seed_line_items(200) # baseline so the cache is never legitimately empty
        view.rebuild!(confirm: true)

        result = BenchmarkSupport::ConcurrentWorkload.new(view: view, adapter: profile.key, table: "mv_concurrent").run

        expect(result.all_ok?).to be(true)    # no worker crash/error; no torn/missing read (#81)
        expect(result.converged?).to be(true) # the system re-converges after the storm
      end
    end
  end
end
