# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'json'
require 'tmpdir'
require 'fileutils'

# Target-native acceptance coverage for patchbot::patch's POSIX
# implementation (04.1-03-PLAN.md Task 2). patchbot is a task-only module
# for Linux targets -- there is no manifest/catalog to compile against a
# running node here, so "acceptance" means invoking the REAL tasks/patch.sh
# binary as a real subprocess (mirroring stagehand's
# spec/acceptance/platform_lock_spec.rb Open3.capture3 pattern), not a
# stubbed rspec-puppet catalog assertion. tasks/patch_test.sh already
# covers the full adversarial matrix (argument injection, embedded
# whitespace, every failure branch) via its own shell harness -- this spec
# is deliberately narrower: it proves the success path end-to-end through
# a real `sh` process, real jq, and a real (stubbed-PATH) package-manager
# invocation, parsed back through Ruby's JSON parser rather than shell
# string comparison, as independent evidence the two harnesses agree.
RSpec.describe 'patchbot::patch (POSIX, target-native acceptance)' do
  let(:repo_root) { File.expand_path('../..', __dir__) }
  let(:task_sh) { File.join(repo_root, 'tasks', 'patch.sh') }

  def with_apt_stub(work_dir, fail: false)
    shim_dir = File.join(work_dir, 'shims')
    FileUtils.mkdir_p(shim_dir)
    shim_path = File.join(shim_dir, 'apt-get')
    File.write(shim_path, <<~SHIM)
      #!/bin/sh
      printf 'apt-get %s\\n' "$*" >> "#{work_dir}/argv.log"
      exit #{fail ? 1 : 0}
    SHIM
    FileUtils.chmod(0o755, shim_path)
    shim_dir
  end

  def run_task(env)
    Open3.capture3(env, 'sh', task_sh)
  end

  around do |example|
    Dir.mktmpdir('patchbot-acceptance-') do |dir|
      @work_dir = dir
      example.run
    end
  end

  it 'runs the real patch.sh subprocess end-to-end and emits parseable compliant JSON on success' do
    shim_dir = with_apt_stub(@work_dir, fail: false)
    real_jq_dir = File.dirname(`command -v jq`.strip)

    stdout, stderr, status = run_task(
      'PATH' => "#{shim_dir}:#{real_jq_dir}:/usr/bin:/bin",
      'HOME' => ENV.fetch('HOME', @work_dir),
    )

    expect(status).to be_success, "patch.sh exited #{status.exitstatus}, stderr: #{stderr}"

    evidence = JSON.parse(stdout)
    expect(evidence).to eq(
      'status' => 'patched',
      'applied' => 'all',
      'reboot_required' => false,
      'rebooted' => false,
    )

    argv_log = File.join(@work_dir, 'argv.log')
    expect(File.exist?(argv_log)).to be true
    expect(File.read(argv_log)).to match(/^apt-get -qq update/)
  end

  it 'runs the real patch.sh subprocess end-to-end and emits parseable error JSON when the package manager fails' do
    shim_dir = with_apt_stub(@work_dir, fail: true)
    real_jq_dir = File.dirname(`command -v jq`.strip)

    stdout, stderr, status = run_task(
      'PATH' => "#{shim_dir}:#{real_jq_dir}:/usr/bin:/bin",
      'HOME' => ENV.fetch('HOME', @work_dir),
    )

    # patch.sh's business-logic failures embed JSON and exit 0 (AUDIT-04) --
    # only setup/argv-validation failures use a nonzero exit.
    expect(status).to be_success, "patch.sh exited #{status.exitstatus}, stderr: #{stderr}"

    evidence = JSON.parse(stdout)
    expect(evidence.fetch('status')).to eq('error')
    expect(evidence.fetch('error')).to eq('apt-get update failed')
  end

  it 'rejects an argument-injection patch_id before ever invoking the package manager' do
    shim_dir = with_apt_stub(@work_dir, fail: false)
    real_jq_dir = File.dirname(`command -v jq`.strip)

    stdout, stderr, status = run_task(
      'PATH' => "#{shim_dir}:#{real_jq_dir}:/usr/bin:/bin",
      'HOME' => ENV.fetch('HOME', @work_dir),
      'PT_patch_ids' => '["--allow-downgrades"]',
    )

    expect(status).not_to be_success
    expect(stdout).to eq('')
    expect(stderr).to match(/patch_ids contains an invalid identifier/)

    argv_log = File.join(@work_dir, 'argv.log')
    expect(File.exist?(argv_log)).to be false
  end
end
