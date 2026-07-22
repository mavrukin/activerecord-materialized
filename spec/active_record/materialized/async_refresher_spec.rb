# frozen_string_literal: true

require "spec_helper"

# Connection-lifecycle safety for the in-process background refresher (#133). The debounced drain
# runs `refresh!` (real DML) on a thread the refresher owns, so it must lease a pooled connection and
# return it — otherwise a burst of writes leaks the pool dry. These specs pin that contract; the
# functional refresh behavior is covered by view_refresh_on_change_spec (driven synchronously via
# flush!, which the suite prefers because in-memory SQLite gives each pooled connection its own DB).
RSpec.describe ActiveRecord::Materialized::AsyncRefresher do
  after do
    described_class.reset!
    described_class.paused = false
  end

  it "leases a pooled connection for the drain and returns it afterward (no leak)" do
    pool = ActiveRecord::Base.connection_pool
    pool.release_connection # start from a known state: nothing checked out on this thread

    leased_during_drain = nil
    allow(described_class).to receive(:drain_pending_unlocked) do
      leased_during_drain = pool.active_connection?
    end

    worker = Thread.new { described_class.send(:drain_on_pooled_connection) }
    worker.join

    expect(leased_during_drain).to be_truthy # a connection was leased while draining
    expect(pool.connections.none?(&:in_use?)).to be(true) # the worker checked it back in — nothing leaked
  end

  it "routes the debounced timer-thread drain through the pooled-connection wrapper" do
    allow(described_class).to receive(:drain_on_pooled_connection)
    described_class.paused = false

    view = define_view("mv_async_conn_items", :item_count_by_category) do
      depends_on Item
      refresh_on_change :async
      refresh_debounce 0 # skip the debounce sleep so the timer thread drains immediately
    end
    described_class.enqueue(view)
    described_class.instance_variable_get(:@timer_thread)&.join

    expect(described_class).to have_received(:drain_on_pooled_connection)
  end
end
