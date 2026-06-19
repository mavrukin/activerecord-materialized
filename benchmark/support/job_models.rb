# frozen_string_literal: true

module Job
  class CastInfo < ActiveRecord::Base
    self.table_name = "cast_info"
  end

  class Name < ActiveRecord::Base
    self.table_name = "name"
  end

  class Title < ActiveRecord::Base
    self.table_name = "title"
  end

  class MovieCompany < ActiveRecord::Base
    self.table_name = "movie_companies"
  end

  class MovieInfo < ActiveRecord::Base
    self.table_name = "movie_info"
  end

  class AkaName < ActiveRecord::Base
    self.table_name = "aka_name"
  end

  class CharName < ActiveRecord::Base
    self.table_name = "char_name"
  end

  class CompanyName < ActiveRecord::Base
    self.table_name = "company_name"
  end

  class InfoType < ActiveRecord::Base
    self.table_name = "info_type"
  end

  class CompanyType < ActiveRecord::Base
    self.table_name = "company_type"
  end

  class RoleType < ActiveRecord::Base
    self.table_name = "role_type"
  end

  class MovieInfoIdx < ActiveRecord::Base
    self.table_name = "movie_info_idx"
  end

  MODELS = [
    CastInfo,
    Name,
    Title,
    MovieCompany,
    MovieInfo,
    AkaName,
    CharName,
    CompanyName,
    InfoType,
    CompanyType,
    RoleType,
    MovieInfoIdx
  ].freeze

  def self.register_models!
    MODELS.each { |model| ActiveRecord::Materialized::TableModelRegistry.register(model) }
  end
end
