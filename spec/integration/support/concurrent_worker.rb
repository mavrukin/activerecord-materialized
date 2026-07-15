# frozen_string_literal: true

# A spawned (not forked) concurrent-workload worker: a fresh process with no inherited
# native-connection state, so libpq/trilogy connect cleanly per worker — a fork would
# inherit libpq's global state and segfault. Role, counts, adapter, and table come from
# ENV; the connection env (ARM_*) is inherited from the parent. Pass/fail is signalled
# via exit status. Driven by concurrent_workload.rb.
require "bundler/setup"
require "active_record"
require "activerecord/materialized"
require "active_support/time"
require_relative "../adapters"
require_relative "integration_schema"

role = ENV.fetch("ARM_WORKER_ROLE")
worker_id = Integer(ENV.fetch("ARM_WORKER_ID"))
iterations = Integer(ENV.fetch("ARM_WORKER_ITERATIONS"))
adapter = ENV.fetch("ARM_WORKER_ADAPTER").to_sym

begin
  Time.use_zone("UTC") do
    ActiveRecord::Base.establish_connection(IntegrationAdapters.connection_config(adapter))
    IntegrationSchema.register_models! # attach models to existing tables (parent provisioned them)
    view = IntegrationSchema.define_scoped_view(ENV.fetch("ARM_WORKER_TABLE"))

    case role
    when "writer"
      iterations.times do |i|
        IntegrationSchema::LineItem.create!(category: "cat-#{i % 5}", sku: "s#{worker_id}", amount: i + 1)
      rescue ActiveRecord::Materialized::Refresher::RefreshError
        nil # maintenance deferred under concurrency; the write is durable (see concurrent_workload.rb)
      end
    when "reader"
      iterations.times { raise "torn read: empty cache during concurrent maintenance" if view.unscoped.none? }
    end
  end
  exit 0
rescue StandardError => e
  warn "[concurrent_worker:#{role}##{worker_id}] #{e.class}: #{e.message.lines.first&.strip}"
  exit 1
end
