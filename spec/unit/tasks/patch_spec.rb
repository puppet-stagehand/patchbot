# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'the patchbot::patch task' do
  let(:task_json_path) { File.expand_path('../../../tasks/patch.json', __dir__) }
  let(:task_sh_path) { File.expand_path('../../../tasks/patch.sh', __dir__) }
  let(:task_ps1_path) { File.expand_path('../../../tasks/patch.ps1', __dir__) }
  let(:metadata) { JSON.parse(File.read(task_json_path)) }
  let(:sh_source) { File.read(task_sh_path) }
  let(:ps1_source) { File.read(task_ps1_path) }

  describe 'metadata contract (AUDIT-03)' do
    it 'accepts params via both stdin and environment' do
      expect(metadata.fetch('input_method')).to eq('both')
    end

    it 'marks ingest_token sensitive so it is never logged in plain text' do
      expect(metadata.dig('parameters', 'ingest_token', 'sensitive')).to be true
    end

    it 'dispatches to the POSIX and Windows implementations by requirement' do
      implementations = metadata.fetch('implementations')
      names_by_requirement = implementations.each_with_object({}) do |impl, acc|
        acc[impl.fetch('requirements').first] = impl.fetch('name')
      end
      expect(names_by_requirement).to eq('shell' => 'patch.sh', 'powershell' => 'patch.ps1')
    end

    it 'validates patch_ids with a strict allowlist regex, never permitting a leading dash' do
      pattern = metadata.dig('parameters', 'patch_ids', 'type')
      expect(pattern).to include('Pattern[/\\A[A-Za-z0-9][A-Za-z0-9._:+-]*\\z/]')
    end

    it 'defaults security_only and reboot to false' do
      expect(metadata.dig('parameters', 'security_only', 'default')).to be false
      expect(metadata.dig('parameters', 'reboot', 'default')).to be false
    end
  end

  describe 'patch.sh source contract' do
    it 'defines die() for setup failures per the module-wide convention' do
      expect(sh_source).to match(/die\(\)\s*\{/)
    end

    it 'defines fail_json() for business-logic failures, embedding JSON on stdout and exiting 0' do
      expect(sh_source).to match(/fail_json\(\)\s*\{/)
    end

    it 'validates patch_ids against the allowlist regex before using it on a command line' do
      expect(sh_source).to match(%r{\^\[A-Za-z0-9\]\[A-Za-z0-9._:\+-\]\*\$})
    end
  end

  describe 'patch.ps1 source contract' do
    it 'defines Fail() for setup failures (stderr + exit 1)' do
      expect(ps1_source).to match(/function Fail\(/)
    end

    it 'defines FailJson() for business-logic failures (embedded JSON + exit 0)' do
      expect(ps1_source).to match(/function FailJson\(/)
    end

    it 'guards the best-effort patchbot-fact refresh against a missing $env:ProgramData' do
      # Regression for the bug 04.1-03-PLAN.md Task 1 fixed: an unguarded
      # Join-Path against an empty ProgramData threw an unhandled
      # terminating error before the script could emit its JSON result.
      expect(ps1_source).to match(/if\s*\(\$env:ProgramData\)\s*\{/)
    end

    it 'never reboots without first emitting the result JSON' do
      reboot_branch = ps1_source[/if \(\$DoReboot -and \$rebootRequired\) \{.*?\n\}/m]
      expect(reboot_branch).not_to be_nil
      json_index = reboot_branch.index('ConvertTo-Json')
      start_process_index = reboot_branch.index('Start-Process')
      expect(json_index).not_to be_nil
      expect(start_process_index).not_to be_nil
      expect(json_index).to be < start_process_index
    end
  end
end
