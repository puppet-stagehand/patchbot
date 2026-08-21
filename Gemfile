source 'https://rubygems.org'

# CI_PUPPET_GEM_NAME/CI_PUPPET_GEM_VERSION let the release CI matrix (see
# .github/workflows/ci.yml) select Puppet Core vs OpenVox and a version
# range without editing this file per leg. OpenVox ships as the "openvox"
# gem but is a drop-in for the "puppet" gem's own Puppet:: Ruby namespace,
# so rspec-puppet/rspec-puppet-facts work unchanged against either — this
# is purely a gem-name/version swap, no test code branches on which one is
# loaded. Local `bundle install` with no env vars set behaves exactly as
# before (Puppet 8.10, unpinned to the two-digit minor).
puppet_gem_name = ENV['CI_PUPPET_GEM_NAME'] || 'puppet'
puppet_gem_version = ENV['CI_PUPPET_GEM_VERSION'] || '~> 8.10'

group :test do
  gem puppet_gem_name, puppet_gem_version
  gem 'puppetlabs_spec_helper', '~> 8.0'
  gem 'rspec-puppet', '~> 5.0'
  gem 'rspec-puppet-facts', '~> 6.1'
  # Without this gem, puppetlabs_spec_helper's metadata_lint rake task
  # silently skips ("the metadata-json-lint gem was not found") instead of
  # failing -- a validate/lint/metadata_lint CI job that can't actually
  # fail on bad metadata.json is a check in name only.
  gem 'metadata-json-lint', '~> 4.0'
end
