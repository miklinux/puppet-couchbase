# frozen_string_literal: true

# couchbase_version: version and build of the installed Couchbase Server,
# exactly as the server reports it, e.g. "7.6.3-4200". Not set when Couchbase
# Server is not installed.
Facter.add(:couchbase_version) do
  confine kernel: 'Linux'

  version_file = '/opt/couchbase/VERSION.txt'
  confine { File.readable?(version_file) }

  setcode do
    version = File.read(version_file).strip
    version.empty? ? nil : version
  end
end
