# frozen_string_literal: true

module AppQuery
  # Maps query results to Ruby objects (e.g., Data classes, Structs).
  #
  # By default, looks for an `Item` constant in the query class.
  # Use `map_to` to specify a different class.
  #
  # @example With default Item class
  #   class ArticlesQuery < ApplicationQuery
  #     include AppQuery::Mappable
  #
  #     class Item < Data.define(:title, :url, :published_on)
  #     end
  #   end
  #
  #   articles = ArticlesQuery.new.entries
  #   articles.first.title  # => "Hello World"
  #
  # @example With explicit map_to
  #   class ArticlesQuery < ApplicationQuery
  #     include AppQuery::Mappable
  #     map_to :article
  #
  #     class Article < Data.define(:title, :url)
  #     end
  #   end
  #
  # @example Skip mapping with raw
  #   articles = ArticlesQuery.new.raw.entries
  #   articles.first  # => {"title" => "Hello", "url" => "..."}
  module Mappable
    extend ActiveSupport::Concern

    class_methods do
      def map_to(name = nil)
        name ? @map_to = name : @map_to
      end
    end

    def raw
      @raw = true
      self
    end

    def select_all
      map_result(super)
    end

    def select_one
      map_one(super)
    end

    private

    def map_result(result)
      return result if @raw
      return result unless (klass = resolve_map_klass)

      attrs = klass.members
      result.transform! { |row| klass.new(**row.symbolize_keys.slice(*attrs)) }
    end

    def map_one(result)
      return result if @raw
      return result unless (klass = resolve_map_klass)
      return result unless result

      attrs = klass.members
      klass.new(**result.symbolize_keys.slice(*attrs))
    end

    def resolve_map_klass
      case (name = self.class.map_to)
      when Symbol
        self.class.const_get(name.to_s.classify)
      when Class
        name
      when nil
        self.class.const_get(:Item) if self.class.const_defined?(:Item)
      end
    end
  end
end
