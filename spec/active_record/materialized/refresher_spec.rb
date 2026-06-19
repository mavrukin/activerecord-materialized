# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::Refresher do
  let(:view_class) do
    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_sales_summary"

      materialized_from { ViewSources.sales_by_category }
    end
  end

  before do
    Item.delete_all
    Item.create!(category: "books", amount: 10)
    Item.create!(category: "books", amount: 5)
    Item.create!(category: "games", amount: 20)
  end

  describe "#refresh!" do
    it "materializes query results into the cache table" do
      result = described_class.new(view_class).refresh!

      expect(result.row_count).to eq(2)
      expect(view_class.order(:category).pluck(:category, :total_amount)).to eq([
                                                                                  ["books", 15],
                                                                                  ["games", 20]
                                                                                ])
    end

    it "records metadata after refresh" do
      travel_to Time.zone.local(2026, 1, 15, 12, 0, 0) do
        described_class.new(view_class).refresh!
        expect(view_class.last_refreshed_at).to eq(Time.zone.local(2026, 1, 15, 12, 0, 0))
        expect(view_class.metadata.row_count).to eq(2)
        expect(view_class.metadata.refreshing?).to be(false)
      end
    end

    it "runs refresh callbacks" do
      events = []
      view_class.before_refresh { events << :before }
      view_class.after_refresh { events << :after }

      described_class.new(view_class).refresh!
      expect(events).to eq(%i[before after])
    end

    it "updates results when source data changes" do
      described_class.new(view_class).refresh!
      item = Item.create!(category: "books", amount: 100)
      view_class.record_write_change!(ActiveRecord::Materialized::WriteChange.from_record(item, :create))

      described_class.new(view_class).refresh!
      books_total = view_class.find_by(category: "books").total_amount
      expect(books_total).to eq(115)
    end

    context "with default incremental maintenance" do
      let(:view_class) do
        Class.new(ActiveRecord::Materialized::View) do
          self.table_name = "mv_default_incremental"

          materialized_from { ViewSources.sales_by_category_with_totals }
        end
      end

      before do
        Item.delete_all
        Item.create!(category: "books", amount: 10)
        Item.create!(category: "games", amount: 20)
      end

      it "bootstraps with a full refresh when the cache table is missing" do
        result = described_class.new(view_class).refresh!

        expect(result.row_count).to eq(2)
        expect(view_class.order(:category).pluck(:category, :total_amount)).to eq(
          [["books", 10], ["games", 20]]
        )
      end

      it "maintains affected partitions in place on subsequent refreshes" do
        described_class.new(view_class).refresh!
        item = Item.create!(category: "books", amount: 5)
        view_class.record_write_change!(ActiveRecord::Materialized::WriteChange.from_record(item, :create))

        connection = ActiveRecord::Base.connection
        allow(connection).to receive(:execute).and_call_original
        described_class.new(view_class).refresh!

        expect(connection).not_to have_received(:execute)
        expect(view_class.find_by(category: "books").total_amount).to eq(15)
        expect(view_class.find_by(category: "games").total_amount).to eq(20)
      end
    end
  end
end
