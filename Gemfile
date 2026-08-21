source ENV['GEM_SOURCE'] || 'https://rubygems.org'

group :test do
  gem 'voxpupuli-test', '~> 14.0',  :require => false
  gem 'puppet_metadata', '~> 6.1',  :require => false
end

group :development do
  gem 'guard-rake',               :require => false
  gem 'overcommit', '>= 0.39.1',  :require => false
end

group :system_tests do
  gem 'puppet_litmus', '~> 2.5', :require => false
  gem 'voxpupuli-acceptance', '~> 4.4',  :require => false
end

group :release do
  gem 'voxpupuli-release', '~> 5.3',  :require => false
end

group :security do
  gem 'bundler-audit', :require => false
end

gem 'rake', :require => false

# metadata.json declares puppet >= 7.0.0 < 9.0.0 (no puppet 9.x RubyGem
# exists) and openvox >= 8.0.0 < 10.0.0. Pick one explicitly for a local
# run with PUPPET_GEM_VERSION (e.g. '~> 7.0', '~> 8.0'); otherwise default
# to the openvox gem, pinned with OPENVOX_GEM_VERSION (e.g. '~> 8.0',
# '>= 9.0.0.a' -- openvox 9 is beta-only upstream as of 2026-07-15; note
# '~> 9.0.0.pre' does NOT match any published prerelease -- rubygems'
# pessimistic operator needs '>= 9.0.0.a' or an exact version like
# '9.0.0.pre.beta2' to select a 9.x prerelease at all).
#
# KNOWN, EXPECTED CONFLICT: `bundle install` with an openvox >= 8.24
# constraint (which includes every current 9.x prerelease) will always fail
# to resolve as long as the :system_tests group is in play -- openvox >=
# 8.24.0 depends on puppet-resource_api ~> 2.0, while puppet_litmus's `bolt`
# dependency chain still needs puppet-resource_api ~> 1.5-compatible puppet.
# `bundle config set without` does not avoid this: bundler still resolves
# every group into one lockfile regardless of --without/BUNDLE_WITHOUT, it
# only skips *installing* the excluded groups' gems. This is exactly why
# CI's openvox9 dependency-resolution job is best-effort/continue-on-error
# rather than required -- see .github/workflows/ci.yml.
if ENV['PUPPET_GEM_VERSION']
  gem 'puppet', ENV['PUPPET_GEM_VERSION'], :require => false, :groups => [:test]
else
  gem 'openvox', ENV.fetch('OPENVOX_GEM_VERSION', [">= 8", "< 10"]), :require => false, :groups => [:test]
end

# vim: syntax=ruby
