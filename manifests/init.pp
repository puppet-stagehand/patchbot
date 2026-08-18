# @summary Puppet Patchbot (patchbot) — patch posture fact + refresh timer.
#
# This is the **pull path** for patch posture: `include patchbot` and, on its
# next Puppet run, the `patchbot` external fact
# (available/security/reboot_required) reaches the console via PuppetDB — the
# Patching page and Action Center read it with no Bolt push.
#
# The fact script itself ships in the module's `facts.d/` and is delivered to
# agents by pluginsync; this class only guarantees the OS package metadata the
# fact counts against stays reasonably fresh, so the numbers are meaningful
# between agent runs.
#
# The active `patchbot::patch` Bolt task (console "Patch" button) is the push
# complement; it does not need this class.
#
# Dependency-light on purpose: manages the refresh timer with native systemd
# unit files (no puppet/systemd dependency), so the module pins nothing.
# Windows is a deliberate no-op here (the $refresh_cmd selector below has no
# 'windows' branch, so this class manages nothing on Windows nodes) — Windows
# Update maintains its own metadata, there's no apt/dnf-style local cache to
# refresh, and facts.d/patchbot.ps1 queries WUA live on every fact run.
#
# @param manage_cache
#   Keep the package manager's update metadata fresh (a small systemd timer)
#   so the fact's counts are current. Default true.
# @param cache_refresh
#   systemd OnCalendar expression for the refresh timer. Default 'daily'.
#
# @example
#   include patchbot
class patchbot (
  Boolean   $manage_cache  = true,
  String[1] $cache_refresh = 'daily',
) {
  # The fact is delivered by pluginsync from patchbot/facts.d/patchbot.sh;
  # nothing to manage here for the fact itself. Keep metadata fresh so counts
  # are live.
  if $manage_cache {
    $refresh_cmd = $facts['os']['family'] ? {
      'Debian' => '/usr/bin/apt-get -qq update',
      'RedHat' => '/usr/bin/dnf -q makecache',
      default  => undef,
    }

    if $refresh_cmd =~ String[1] {
      $unit = 'patchbot-refresh'

      file { "/etc/systemd/system/${unit}.service":
        ensure  => file,
        owner   => 'root',
        group   => 'root',
        mode    => '0644',
        content => "[Unit]\nDescription=patchbot: refresh package metadata for the patchbot fact\n\n[Service]\nType=oneshot\nExecStart=${refresh_cmd}\n",
        notify  => Exec['patchbot-systemd-daemon-reload'],
      }

      file { "/etc/systemd/system/${unit}.timer":
        ensure  => file,
        owner   => 'root',
        group   => 'root',
        mode    => '0644',
        content => "[Unit]\nDescription=patchbot: schedule package-metadata refresh for the patchbot fact\n\n[Timer]\nOnCalendar=${cache_refresh}\nRandomizedDelaySec=1h\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n",
        notify  => Exec['patchbot-systemd-daemon-reload'],
      }

      exec { 'patchbot-systemd-daemon-reload':
        command     => '/usr/bin/systemctl daemon-reload',
        refreshonly => true,
      }

      service { "${unit}.timer":
        ensure  => running,
        enable  => true,
        require => [File["/etc/systemd/system/${unit}.timer"], Exec['patchbot-systemd-daemon-reload']],
      }
    }
  }
}
