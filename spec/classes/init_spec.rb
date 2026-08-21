# frozen_string_literal: true

require 'spec_helper'

describe 'patchbot' do
  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      context 'with default parameters' do
        it { is_expected.to compile.with_all_deps }

        case os_facts[:os]['family']
        when 'Debian'
          it { is_expected.to have_file_resource_count(2) }

          it {
            is_expected.to contain_file('/etc/systemd/system/patchbot-refresh.service')
              .with_ensure('file')
              .with_owner('root')
              .with_group('root')
              .with_mode('0644')
              .with_content(%r{/usr/bin/apt-get -qq update})
              .that_notifies('Exec[patchbot-systemd-daemon-reload]')
          }

          it {
            is_expected.to contain_file('/etc/systemd/system/patchbot-refresh.timer')
              .with_content(%r{OnCalendar=daily})
              .that_notifies('Exec[patchbot-systemd-daemon-reload]')
          }

          it {
            is_expected.to contain_exec('patchbot-systemd-daemon-reload')
              .with_command('/usr/bin/systemctl daemon-reload')
              .with_refreshonly(true)
          }

          it {
            is_expected.to contain_service('patchbot-refresh.timer')
              .with_ensure('running')
              .with_enable(true)
          }
        when 'RedHat'
          it {
            is_expected.to contain_file('/etc/systemd/system/patchbot-refresh.service')
              .with_content(%r{/usr/bin/dnf -q makecache})
          }

          it { is_expected.to contain_service('patchbot-refresh.timer') }
        when 'windows'
          it { is_expected.to have_file_resource_count(0) }
          it { is_expected.not_to contain_service('patchbot-refresh.timer') }
        end
      end

      context 'with manage_cache => false' do
        let(:params) { { 'manage_cache' => false } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to have_file_resource_count(0) }
        it { is_expected.not_to contain_service('patchbot-refresh.timer') }
      end

      next unless %w[Debian RedHat].include?(os_facts[:os]['family'])

      context 'with a custom cache_refresh schedule' do
        let(:params) { { 'cache_refresh' => 'hourly' } }

        it { is_expected.to compile.with_all_deps }

        it {
          is_expected.to contain_file('/etc/systemd/system/patchbot-refresh.timer')
            .with_content(%r{OnCalendar=hourly})
        }
      end
    end
  end

  context 'on an unsupported OS family (no refresh command mapping)' do
    let(:facts) do
      {
        os: { family: 'Solaris', name: 'Solaris', release: { major: '11', full: '11.4' } },
        kernel: 'SunOS',
        osfamily: 'Solaris',
      }
    end

    it { is_expected.to compile.with_all_deps }
    it { is_expected.to have_file_resource_count(0) }
  end
end
