require 'spec_helper'

describe 'patchbot' do
  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      context 'with default parameters' do
        it { is_expected.to compile.with_all_deps }
        it { is_expected.to have_class_count(1) }
      end

      context 'when manage_cache => false' do
        let(:params) { { 'manage_cache' => false } }

        it { is_expected.to compile.with_all_deps }

        it 'manages no systemd units at all' do
          is_expected.not_to contain_file('/etc/systemd/system/patchbot-refresh.service')
          is_expected.not_to contain_file('/etc/systemd/system/patchbot-refresh.timer')
          is_expected.not_to contain_service('patchbot-refresh.timer')
        end
      end

      case os_facts[:os]['family']
      when 'Debian'
        context 'with default parameters (manage_cache => true)' do
          it {
            is_expected.to contain_file('/etc/systemd/system/patchbot-refresh.service')
              .with_ensure('file')
              .with_owner('root')
              .with_group('root')
              .with_mode('0644')
              .with_content(%r{ExecStart=/usr/bin/apt-get -qq update})
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
              .that_requires([
                                'File[/etc/systemd/system/patchbot-refresh.timer]',
                                'Exec[patchbot-systemd-daemon-reload]',
                              ])
          }
        end

        context 'with cache_refresh => weekly' do
          let(:params) { { 'cache_refresh' => 'weekly' } }

          it { is_expected.to contain_file('/etc/systemd/system/patchbot-refresh.timer').with_content(%r{OnCalendar=weekly}) }
        end
      when 'RedHat'
        context 'with default parameters (manage_cache => true)' do
          it {
            is_expected.to contain_file('/etc/systemd/system/patchbot-refresh.service')
              .with_content(%r{ExecStart=/usr/bin/dnf -q makecache})
          }

          it { is_expected.to contain_service('patchbot-refresh.timer').with_ensure('running').with_enable(true) }
        end
      end
    end
  end

  # Windows is a deliberate no-op: the $refresh_cmd selector has no
  # 'windows' branch, so with manage_cache => true (the default) on a
  # Windows-family node, the guard `if $refresh_cmd =~ String[1]` never
  # enters and nothing is managed at all -- not even a conditional skip
  # message, per design (see manifests/init.pp's header comment).
  context 'on Windows' do
    let(:facts) do
      {
        os: { family: 'windows', name: 'windows', release: { major: '2022' } },
        kernel: 'windows',
        osfamily: 'windows',
      }
    end

    it { is_expected.to compile.with_all_deps }

    it 'manages nothing (Windows Update maintains its own metadata)' do
      is_expected.not_to contain_file('/etc/systemd/system/patchbot-refresh.service')
      is_expected.not_to contain_file('/etc/systemd/system/patchbot-refresh.timer')
      is_expected.not_to contain_exec('patchbot-systemd-daemon-reload')
      is_expected.not_to contain_service('patchbot-refresh.timer')
    end
  end
end
