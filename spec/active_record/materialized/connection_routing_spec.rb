# frozen_string_literal: true

require "spec_helper"

# #94 — routes maintenance to the primary and verification reads to a replica when the app has
# declared the Rails multi-database roles; an unset (nil) role yields on the current connection.
RSpec.describe ActiveRecord::Materialized::ConnectionRouting do
  let(:config) { ActiveRecord::Materialized.configuration }

  after do
    config.maintenance_role = nil
    config.verification_role = nil
  end

  it "yields on the current connection when no role is configured (default)" do
    # No connects_to roles exist in the test app, so routing must not touch connected_to.
    allow(ActiveRecord::Base).to receive(:connected_to)

    expect(described_class.maintenance { :ran }).to eq(:ran)
    expect(described_class.verification { :ran }).to eq(:ran)
    expect(ActiveRecord::Base).not_to have_received(:connected_to)
  end

  it "runs the block under the configured role for each kind of work" do
    config.maintenance_role = :writing
    config.verification_role = :reading
    allow(ActiveRecord::Base).to receive(:connected_to).and_yield # no real replica in the test app

    described_class.maintenance { :m }
    described_class.verification { :v }

    expect(ActiveRecord::Base).to have_received(:connected_to).with(role: :writing)
    expect(ActiveRecord::Base).to have_received(:connected_to).with(role: :reading)
  end
end
