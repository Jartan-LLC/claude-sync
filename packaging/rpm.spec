# packaging/rpm.sh builds this spec. Write no percent sign in a comment: rpm expands
# macros there too.
Name:           claude-sync
# packaging/rpm.sh defines tag_version from its VERSION argument.
Version:        %{tag_version}
# One package for every RPM distribution, so no dist suffix.
Release:        1
Summary:        Continuous sync of ~/.claude across devices with Syncthing
License:        MIT
URL:            https://github.com/Jartan-LLC/claude-sync
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch

BuildRequires:  bash
BuildRequires:  coreutils
BuildRequires:  grep
BuildRequires:  sed
Requires:       bash
Requires:       coreutils
Requires:       curl
Requires:       findutils
Requires:       grep
Requires:       sed

%description
claude-sync keeps ~/.claude in sync across devices: change a setting or write a
memory on one machine, and it is there on the others. It runs Syncthing in a
Docker container, which needs Docker Engine 25 or newer with its Compose plugin.
It can instead add its folder to a Syncthing already running on the host.

%prep
%autosetup

%build
packaging/build.sh %{version} dist/claude-sync

%install
install -Dpm 0755 dist/claude-sync %{buildroot}%{_bindir}/claude-sync

%check
test "$(dist/claude-sync version)" = "claude-sync %{version}"

%files
%license LICENSE
%doc README.md CHANGELOG.md docs/commands.md docs/own-syncthing.md docs/pairing.md docs/recovering-files.md
%{_bindir}/claude-sync
