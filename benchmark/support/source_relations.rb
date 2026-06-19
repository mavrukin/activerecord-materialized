# frozen_string_literal: true

require_relative "benchmark_sources/cast_aggregate_relations"
require_relative "benchmark_sources/cast_coappearance_relation"
require_relative "benchmark_sources/production_notes_relation"
require_relative "benchmark_sources/voice_cast_relations"

module BenchmarkSources
  extend CastAggregateRelations
  extend CastCoappearanceRelation
  extend ProductionNotesRelation
  extend VoiceCastRelations

  module_function

  def gender_pairing_stats_relation
    CastAggregateRelations.gender_pairing_stats_relation
  end

  def company_movie_cross_relation
    CastAggregateRelations.company_movie_cross_relation
  end

  def person_movie_network_relation
    CastAggregateRelations.person_movie_network_relation
  end

  def cast_coappearance_relation
    CastCoappearanceRelation.cast_coappearance_relation
  end

  def production_notes_relation
    ProductionNotesRelation.production_notes_relation
  end

  def voicing_actresses_relation
    VoiceCastRelations.voicing_actresses_relation
  end

  def russian_voice_actors_relation
    VoiceCastRelations.russian_voice_actors_relation
  end
end
