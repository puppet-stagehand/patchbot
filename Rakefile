begin
  require 'voxpupuli/test/rake'
rescue LoadError
  # only available if gem group test is installed
end

begin
  require 'voxpupuli/acceptance/rake'
rescue LoadError
  # only available if gem group acceptance is installed
end

begin
  require 'puppet_litmus/rake_tasks'
rescue LoadError
  # only available if the system_tests bundle is installed
end

require 'fileutils'
task :spec_prep do
  FileUtils.mkdir_p('spec/fixtures')
end

begin
  require 'voxpupuli/release/rake_tasks'
rescue LoadError
  # only available if gem group releases is installed
else
  GCGConfig.user = 'puppet-stagehand'
  GCGConfig.project = 'patchbot'
end

desc "Run main 'test' task and report merged results to coveralls"
task test_with_coveralls: [:test] do
  if Dir.exist?(File.expand_path('../lib', __FILE__))
    require 'coveralls/rake/task'
    Coveralls::RakeTask.new
    Rake::Task['coveralls:push'].invoke
  else
    puts 'Skipping reporting to coveralls.  Module has no lib dir'
  end
end

# vim: syntax=ruby
