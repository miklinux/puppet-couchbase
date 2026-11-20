# frozen_string_literal: true

module PuppetX
  module Couchbase
    # Helpers to convert Couchbase RBAC roles between the string form used by
    # the REST API on writes (`data_reader[bucket:scope:collection]`) and the
    # JSON objects it returns on reads, and to put them in a canonical form so
    # that Puppet can compare them reliably.
    #
    # Canonical form:
    #   * cluster-wide roles: `admin`, `ro_admin`, ...
    #   * parameterised roles: `role[bucket]`, `role[bucket:scope]`,
    #     `role[bucket:scope:collection]`; trailing `*` for scope/collection
    #     are dropped (`data_reader[b:*:*]` == `data_reader[b]`), while the
    #     bucket is always kept (`bucket_admin[*]`).
    module Role
      ROLE_RE = /\A\s*([a-z][a-z0-9_]*)\s*(?:\[\s*([^\]]*?)\s*\])?\s*\z/

      module_function

      def valid?(role)
        !(role.to_s =~ ROLE_RE).nil?
      end

      def parse(role)
        m = ROLE_RE.match(role.to_s)
        raise ArgumentError, "Invalid Couchbase role '#{role}', expected e.g. 'admin' or 'data_reader[bucket:scope:collection]'" unless m

        params = m[2].nil? ? [] : m[2].split(':', -1).map(&:strip)
        raise ArgumentError, "Invalid Couchbase role '#{role}': empty or too many [] parameters" if m[2] && (params.empty? || params.size > 3 || params.any?(&:empty?))

        [m[1], params]
      end

      def build(name, params)
        params = Array(params).map(&:to_s)
        # Strip wildcard scope / collection, never the bucket.
        params.pop while params.size > 1 && params.last == '*'
        params.empty? ? name : "#{name}[#{params.join(':')}]"
      end

      def normalize(role)
        name, params = parse(role)
        build(name, params)
      end

      def normalize_all(roles)
        Array(roles).flatten.compact.map { |r| normalize(r) }.uniq.sort
      end

      # Converts one role object as returned by GET /settings/rbac/... .
      def from_api(obj)
        params = [obj['bucket_name'], obj['scope_name'], obj['collection_name']]
        params.pop while !params.empty? && params.last.nil?
        build(obj['role'], params.map { |p| p.nil? ? '*' : p })
      end

      # Roles granted directly to a user (not inherited through a group).
      # Group objects carry no `origins`, so everything counts as direct.
      def direct_from_api(role_objects)
        Array(role_objects).select { |obj|
          origins = obj['origins']
          origins.nil? || origins.empty? || origins.any? { |o| o['type'] == 'user' }
        }.map { |obj| from_api(obj) }.uniq.sort
      end

      # Bucket referenced by a role, if any (used for autorequire).
      def bucket(role)
        _name, params = parse(role)
        b = params.first
        (b.nil? || b == '*') ? nil : b
      end
    end
  end
end
