# frozen_string_literal: true

namespace :materialized do
  desc "Refresh all registered materialized views"
  task refresh_all: :environment do
    ActiveRecord::Materialized::Registry.refresh_all!
    puts "Refreshed #{ActiveRecord::Materialized::Registry.all.size} materialized view(s)."
  end

  desc "Refresh stale materialized views"
  task refresh_stale: :environment do
    stale = ActiveRecord::Materialized::Registry.all.select(&:stale?)
    stale.each(&:refresh!)
    puts "Refreshed #{stale.size} stale materialized view(s)."
  end
end
