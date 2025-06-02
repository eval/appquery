module AppQuery
  class Base
    class_attribute :_cast, default: true, instance_predicate: false
    class_attribute :_default_binds, default: {}, instance_predicate: false

    class << self
      def run(build_only: false, binds: {}, vars: {}, cast: self.cast, select: nil, **)
        _build(binds:, vars:, cast:, select:).then do
          build_only ? _1 : _1.select_all
        end
      end

      def build(**opts)
        run(build_only: true, **opts)
      end

      def default_binds(v = nil)
        return _default_binds if v.nil?
        self._default_binds = v
      end

      def cast(v = nil)
        return _cast if v.nil?
        self._cast = v
      end

      def query_name
        derive_query_name unless defined?(@query_name)
        @query_name
      end

      attr_writer :query_name

      private

      def _build(cast:, binds: {}, select: nil, vars: {})
        AppQuery[query_name, binds:, cast:].render(vars).with_select(select)
      end

      def derive_query_name
        self.query_name = name.underscore.sub(/_query$/, "")
      end
    end
  end
end
