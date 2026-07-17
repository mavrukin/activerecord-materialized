# frozen_string_literal: true

require "spec_helper"
require "active_job"
require "activerecord/materialized/refresh_job"

RSpec.describe ActiveRecord::Materialized::RefreshScheduler do
  let(:view_class) { define_view("mv_scheduler_test", :item_count_by_category) }

  describe ".schedule with the :active_job dispatcher" do
    around do |example|
      previous_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      example.run
      ActiveJob::Base.queue_adapter = previous_adapter
    end

    let(:enqueued) { ActiveJob::Base.queue_adapter.enqueued_jobs }

    before do
      # Opt into :active_job here (not the around) so it runs after spec_helper's :async default.
      ActiveRecord::Materialized.configuration.refresh_dispatcher = :active_job
      seed_items(["books", 1], ["games", 2])
      view_class.rebuild!(confirm: true) # warm + clean, so a write transitions it to dirty
    end

    it "enqueues a single RefreshJob for a burst of writes (coalesced)" do
      expect { 25.times { described_class.schedule(view_class) } }
        .to change(enqueued, :size).by(1)
    end

    it "enqueues again once the view has been refreshed clean" do
      described_class.schedule(view_class)
      view_class.metadata.mark_refreshed!(row_count: 0, duration_ms: 0)

      expect { described_class.schedule(view_class) }.to change(enqueued, :size).by(1)
    end
  end
end
