# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::SchemaVerifier do
  subject(:verifier) { described_class.new(view_class) }

  let(:view_class) { define_view("mv_verify_items", :item_count_by_category) }

  before { seed_items(["books", 1]) }

  it "is a no-op for an unprovisioned view" do
    expect(view_class.table_exists?).to be(false)
    expect { verifier.verify! }.not_to raise_error
    expect(verifier.drifted?).to be(false)
  end

  it "passes when the table matches the relation" do
    view_class.rebuild!(confirm: true)

    expect { verifier.verify! }.not_to raise_error
    expect(verifier.drifted?).to be(false)
  end

  it "raises when the table is missing a projected column" do
    view_class.rebuild!(confirm: true)
    view_class.connection.remove_column(view_class.table_name, :item_count)
    view_class.reset_column_information

    expect { verifier.verify! }
      .to raise_error(described_class::SchemaDriftError, /item_count/)
  end

  it "raises when the table has an unexpected column" do
    view_class.rebuild!(confirm: true)
    view_class.connection.add_column(view_class.table_name, :stale_total, :integer)
    view_class.reset_column_information

    expect { verifier.verify! }
      .to raise_error(described_class::SchemaDriftError, /stale_total/)
  end

  describe "ActiveRecord::Materialized.verify_schema!" do
    it "raises for a drifted registered view" do
      view_class.rebuild!(confirm: true) # registers via materialized_from and provisions the table
      view_class.connection.add_column(view_class.table_name, :rogue, :string)
      view_class.reset_column_information

      expect { ActiveRecord::Materialized.verify_schema! }
        .to raise_error(described_class::SchemaDriftError)
    end
  end
end
