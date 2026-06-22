# frozen_string_literal: true

require_relative "job_models"

module BenchmarkSupport
  # Synthetic writes for the update simulations: inserts cast_info rows for
  # existing female names and post-2000 titles, so the gender-partitioned views
  # gain real pairings to maintain. Shared by verify_updates and lifecycle.
  module CastSimulation
    module_function

    def insert_rows!(count:)
      max_id, female_ids, movie_ids = simulation_ids
      raise "Need seed names and titles for the update simulation" unless female_ids.any? && movie_ids.any?

      ActiveRecord::Base.transaction do
        count.times { |offset| create_row!(max_id, offset, female_ids, movie_ids) }
      end
      count
    end

    def simulation_ids
      [
        Job::CastInfo.maximum(:id).to_i,
        Job::Name.where(gender: "f").limit(100).pluck(:id),
        Job::Title.where(Job::Title.arel_table[:production_year].gt(2000)).limit(100).pluck(:id)
      ]
    end

    def create_row!(max_id, offset, female_ids, movie_ids)
      Job::CastInfo.create!(
        id: max_id + offset + 1,
        person_id: female_ids[offset % female_ids.size],
        movie_id: movie_ids[offset % movie_ids.size],
        person_role_id: 1,
        note: "update-simulation",
        nr_order: offset % 20,
        role_id: 2
      )
    end
  end
end
