require 'findit-support'
require 'cgi' # for escape_html
require_relative './place.rb'
require_relative './jurisdiction.rb'
require_relative './district.rb'
require_relative './response.rb'

class String
  def escape_html
    CGI.escape_html(self)
  end
  def escape_uri
    URI.escape(self)
  end
end

class NilClass
  def empty?
    true
  end
end


module VoteATX

  # Default path to the VoteATX database.
  DATABASE = "db/voteatx.db"

  # Default maxmum distance (miles) of early voting places to consider.
  MAX_DISTANCE = 12

  # Default maximum number of early voting places to display.
  MAX_PLACES = 4

  # When performing a search, if a GeoJSON string for a region polygon
  # exceeds this length then return "true" for the region. The app will
  # need to make a separate request for that region if it wants the polygon.
  MAX_REGION_ON_SEARCH = 8192

  # Implementation of the VoteATX application.
  #
  # Example usage:
  #
  #    require 'voteatx'
  #    finder = VoteATX::Finder.new
  #    places = finder.search(latitude, longitude))
  #
  class Finder

    attr_reader :db

    # Construct a new VoteATX app instance.
    #
    # Options:
    # * :database - Path to the VoteATX database. If not specified, the
    #   value defined by VoteATX::DATABASE is used.
    # * :max_distance - Do not select voting places that are further than
    #   this distance (in miles) from the current location. If not specified,
    #   the value defined by VoteATX::MAX_DISTANCE is used. This value may be
    #   overridden in a #search call.
    # * :max_places - Select at most this number of early voting places. If
    #   not specified, the value defined by VoteATX::MAX_PLACES is used. This
    #   value may be overridden in a #search call.
    #
    def initialize(options = {})
      @search_opts = {}
      @search__opts[:max_places] = options[:max_places] unless options[:max_places].empty?
      @search__opts[:max_distance] = options[:max_distance] unless options[:max_distance].empty?

      database = options[:database] || DATABASE
      raise "database \"#{database}\" not found" unless File.exist?(database)

      @db = Sequel.spatialite(database)
      @db.logger = options[:log] if options.has_key?(:log)
      @db.sql_log_level = :debug
    end


    # Search for features near a given location.
    #
    # Parameters:
    # * lat - the latitude (degrees) of the location, as a Float.
    # * lng - the longitude (degrees) of the location, as a Float.
    # * juris - the jurisdiction identifier, such as "TRAVIS".
    #
    # Options:
    # * :max_distance - Override :max_distance specified for constructor.
    # * :max_locations - Override :max_locations specified for constructor.
    # * :time - A date/time string that is parsed and used for the current time.
    #   This is intended for use in testing.
    #
    def search(lat, lng, jkey, options = {})
      origin = FindIt::Location.new(lat, lng, :DEG)
      juris = VoteATX::Jurisdiction.get(@db, jkey) or raise "jurisdiction \"#{jkey}\" not found"
      now = Time.now

      search_options = {}
      options.each do |k, v|
        next if v.nil? || v.empty?
        case k
        when :time
          begin
            search_options[k] = now = Time.parse(v)
          rescue ArgumentError
            # ignore Time.parse error
          end
        when :max_distance, :max_locations
          search_options[k] = v
        else
          raise "bad option \"#{k}\" specified"
        end
      end

      response = VoteATX::Response.new(juris)

      council_district = VoteATX::District::CityCouncil.find(@db, juris, origin)
      response.add_district(council_district) if council_district

      precinct = VoteATX::District::Precinct.find(@db, juris, origin)
      if ! precinct
        response.error("The location you selected is outside the #{juris.name} election jurisdiction.")
        return response.to_h
      end
      response.add_district(precinct)
      if juris.sample_ballot_url
        response.add_additional(:sample_ballot_url, (juris.sample_ballot_url % precinct.id))
      end

      f = VoteATX::VotingPlace::Finder.new(@db, juris, search_options)
      f.origin = origin

      today = now.to_date
      if today > juris.date_early_voting_ends

        #
        # Election Day algorithm
        #
        places = f.search_election_day_places
        places.each do |p|
          response.add_place(p)
        end

        if today > juris.date_election_day
          response.warning("You are viewing historical data, for the election that was held #{juris.date_election_day.strftime("%b %d, %Y")}.")
        end

      else

        #
        # Early Voting algorithm
        #
        if precinct
          p = f.find_election_day_place_by_precinct(precinct.id)
          response.add_place(p) if p
        end
        places = f.search_early_places
        places.each do |p|
          response.add_place(p)
        end

      end

      return response.to_h
    end

  end # module Finder
end # module VoteATX
