# frozen_string_literal: true

require "spec_helper"
require "erb"

# The install generator's migration must provision the same metadata and
# partition tables the runtime schema creates, so a migrated app and a
# lazily-created one agree.
RSpec.describe ActiveRecord::Materialized::Metadata::Schema do
  let(:template_path) do
    File.expand_path(
      "../../../../lib/generators/activerecord_materialized/install/templates/" \
      "create_ar_materialized_view_metadata.rb.erb",
      __dir__
    )
  end

  let(:rendered) { ERB.new(File.read(template_path)).result(binding) }

  it "renders syntactically valid migration Ruby" do
    expect { RubyVM::InstructionSequence.compile(rendered) }.not_to raise_error
  end

  it "provisions every metadata column the runtime schema creates" do
    %w[
      view_name last_refreshed_at refreshing dirty warm
      row_count refresh_duration_ms last_error maintenance_payload
      last_reconciled_at reconciled_partition_count fresh_set_generation
    ].each { |column| expect(rendered).to include(":#{column}") }
  end

  it "provisions the partition table" do
    expect(rendered).to include("create_table :ar_materialized_view_partitions")
    expect(rendered).to include(":partition_key")
    expect(rendered).to include(":generation") # the fresh-set epoch stamp (#120)
  end
end
