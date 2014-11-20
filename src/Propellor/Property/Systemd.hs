module Propellor.Property.Systemd (
	installed,
	persistentJournal,
	container,
	nspawned,
) where

import Propellor
import qualified Propellor.Property.Chroot as Chroot
import qualified Propellor.Property.Apt as Apt
import Utility.SafeCommand

import Data.List.Utils

type MachineName = String

type NspawnParam = CommandParam

data Container = Container MachineName System [CommandParam] Host

instance Hostlike Container where
        (Container n s ps h) & p = Container n s ps (h & p)
        (Container n s ps h) &^ p = Container n s ps (h &^ p)
        getHost (Container _ _ _ h) = h

-- dbus is only a Recommends of systemd, but is needed for communication
-- from the systemd inside a container to the one outside, so make sure it
-- gets installed.
installed :: Property
installed = Apt.installed ["systemd", "dbus"]

-- | Sets up persistent storage of the journal.
persistentJournal :: Property
persistentJournal = check (not <$> doesDirectoryExist dir) $ 
	combineProperties "persistent systetemd journal"
		[ cmdProperty "install" ["-d", "-g", "systemd-journal", dir]
		, cmdProperty "setfacl" ["-R", "-nm", "g:adm:rx,d:g:adm:rx", dir]
		]
		`requires` Apt.installed ["acl"]
  where
	dir = "/var/log/journal"

-- | Defines a container with a given machine name, containing the specified
-- System. Properties can be added to configure the Container.
--
-- > container "webserver" (System (Debian Unstable) "amd64") []
container :: MachineName -> System -> [NspawnParam] -> Container
container name system ps = Container name system ps (Host name [] mempty)

-- | Runs a container using systemd-nspawn.
--
-- A systemd unit is set up for the container, so it will automatically
-- be started on boot.
--
-- Systemd is automatically installed inside the container, and will
-- communicate with the host's systemd. This allows systemctl to be used to
-- examine the status of services running inside the container.
--
-- When the host system has persistentJournal enabled, journactl can be
-- used to examine logs forwarded from the container.
--
-- Reverting this property stops the container, removes the systemd unit,
-- and deletes the chroot and all its contents.
nspawned :: Container -> RevertableProperty
nspawned c@(Container name system _ h) = RevertableProperty setup teardown
  where
	-- TODO after container is running, use nsenter to enter it
	-- and run propellor to finish provisioning.
	setup = toProp (nspawnService c)
		`requires` toProp chrootprovisioned

	teardown = toProp (revert (chrootprovisioned))
		`requires` toProp (revert (nspawnService c))

	-- When provisioning the chroot, pass a version of the Host
	-- that only has the Property of systemd being installed.
	-- This is to avoid starting any daemons in the chroot,
	-- which would not run in the container's namespace.
	chrootprovisioned = Chroot.provisioned $
		Chroot.Chroot (containerDir name) system $
			h { hostProperties = [installed] }

nspawnService :: Container -> RevertableProperty
nspawnService (Container name _ ps _) = RevertableProperty setup teardown
  where
	service = nspawnServiceName name
	servicefile = "/etc/systemd/system/multi-user.target.wants" </> service

	setup = check (not <$> doesFileExist servicefile) $
		combineProperties ("container running " ++ service)
			[ cmdProperty "systemctl" ["enable", service]
			, cmdProperty "systemctl" ["start", service]
			]

	-- TODO adjust execStart line to reflect ps

	teardown = undefined

nspawnServiceName :: MachineName -> String
nspawnServiceName name = "systemd-nspawn@" ++ name ++ ".service"

containerDir :: MachineName -> FilePath
containerDir name = "/var/lib/container" ++ replace "/" "_" name