"""The deployment's pieces agree with each other, and with the app.

    python3 -m unittest discover -v
    BRAIN_FREEZE_APP=/path/to/brain-freeze python3 -m unittest discover -v

This repository is shell, systemd, HAProxy, Ops Agent and Terraform, joined
by strings: a port in one file is a scrape target in another, a line the app
prints is a log filter in Terraform. Nothing fails when one side changes and
the other does not; the dashboard just goes quiet. So these read both sides
and compare.

The app's side is read from a brain-freeze checkout: BRAIN_FREEZE_APP, or
../brain-freeze beside this repository. Without one, those tests skip.

Nothing here deploys anything. README.md says what has been run for real and
what has not.
"""

import ast
import os
import re
import stat
import subprocess
import unittest

DEPLOY = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NODE = os.path.join(DEPLOY, "node")
TERRAFORM = os.path.join(DEPLOY, "terraform")

#: The brain-freeze checkout whose app this deploys.
APP = os.environ.get("BRAIN_FREEZE_APP",
                     os.path.join(os.path.dirname(DEPLOY), "brain-freeze"))
NEEDS_APP = unittest.skipUnless(
    os.path.isfile(os.path.join(APP, "web", "app.py")),
    "no brain-freeze checkout at %s; set BRAIN_FREEZE_APP" % APP)


def read(*parts):
    with open(os.path.join(*parts)) as handle:
        return handle.read()


def constant(path, name):
    """A module-level string constant, read without importing the module:
    the web modules import flask and gemdb, which CPython does not have."""
    for node in ast.parse(read(path)).body:
        if isinstance(node, ast.Assign) and any(
                getattr(t, "id", None) == name for t in node.targets):
            return node.value.value
    raise AssertionError("%s has no %s" % (path, name))


def haproxy_config(instances):
    finished = subprocess.run(
        [os.path.join(NODE, "bin", "haproxy-config"), str(instances)],
        capture_output=True, text=True)
    if finished.returncode != 0:
        raise AssertionError(finished.stderr)
    return finished.stdout


class HAProxyServesTheInstances(unittest.TestCase):
    def test_one_server_per_instance_on_consecutive_ports(self):
        servers = re.findall(r"^\s+server (app\d+) 127\.0\.0\.1:(\d+)$",
                             haproxy_config(4), re.M)
        self.assertEqual(servers, [("app1", "5051"), ("app2", "5052"),
                                   ("app3", "5053"), ("app4", "5054")])

    def test_the_ports_are_the_ones_the_instances_open(self):
        # run-instance: BASE_PORT + N - 1, with BASE_PORT from node.env,
        # which provision.sh writes.
        self.assertIn("BASE_PORT=5051", read(NODE, "provision.sh"))
        self.assertIn("BASE_PORT + N - 1", read(NODE, "bin", "run-instance"))

    def test_each_instance_gets_one_request_at_a_time(self):
        # brain-freeze's web/app.py, constraints 1 and 2: single-threaded,
        # no keep-alive.
        self.assertIn("default-server maxconn 1", haproxy_config(3))

    @NEEDS_APP
    def test_it_checks_the_route_the_app_answers(self):
        self.assertIn("option httpchk GET /healthz", haproxy_config(3))
        self.assertIn('@ROUTES.route("/healthz")',
                      read(APP, "web", "routes_ops.py"))

    def test_the_public_port_does_not_serve_metrics(self):
        public = haproxy_config(3).split("frontend public")[1].split("frontend")[0]
        self.assertIn("deny deny_status 404 if { path /metrics }", public)

    def test_the_load_balancer_asks_haproxy_what_haproxy_answers(self):
        monitor = re.search(r"monitor-uri (\S+)", haproxy_config(3)).group(1)
        for name in ("lb.tf", "compute.tf"):
            paths = re.findall(r'request_path\s*=\s*"([^"]+)"',
                               read(TERRAFORM, name))
            self.assertTrue(paths, name)
            self.assertEqual(set(paths), {monitor}, name)


class TheAgentScrapesWhatIsServed(unittest.TestCase):
    def targets(self):
        return dict(re.findall(r"job_name: (\w+).*?targets: \[\"([^\"]+)\"\]",
                               read(NODE, "ops-agent.yaml"), re.S))

    def test_haproxys_exporter(self):
        config = haproxy_config(3)
        stats = config.split("frontend stats")[1].split("backend")[0]
        self.assertIn("bind %s" % self.targets()["haproxy"], stats)
        self.assertIn("prometheus-exporter", stats)

    def test_the_apps_metrics_through_the_loopback_port(self):
        internal = haproxy_config(3).split("frontend internal")[1].split("frontend")[0]
        self.assertIn("bind %s" % self.targets()["brainfreeze"], internal)


class TheLogsTerraformCountsAreTheLogsThatAreWritten(unittest.TestCase):
    def filters(self):
        return re.findall(r'jsonPayload\.MESSAGE:\\"([^\\]+)\\"',
                          read(TERRAFORM, "monitoring.tf"))

    @NEEDS_APP
    def test_commit_conflicts(self):
        said = constant(os.path.join(APP, "web", "conflicts.py"), "SAID")
        self.assertIn(said, self.filters())

    def test_backups(self):
        self.assertIn("Backed up to gs://", self.filters())
        self.assertIn('echo "Backed up to gs://', read(NODE, "bin", "backup"))


class TheInstanceLimitIsTheLicensesEverywhere(unittest.TestCase):
    def test_terraform_refuses_more_than_six(self):
        variables = read(TERRAFORM, "variables.tf")
        block = variables.split('variable "app_instances"')[1].split("variable ")[0]
        self.assertIn("var.app_instances <= 6", block)


class EveryUnitRunsAScriptThatIsThere(unittest.TestCase):
    PREFIX = "/var/lib/brainfreeze/deploy/"

    def test_every_exec_line_names_an_executable_in_this_checkout(self):
        checked = 0
        for name in sorted(os.listdir(os.path.join(NODE, "systemd"))):
            for line in read(NODE, "systemd", name).splitlines():
                match = re.match(r"Exec\w*=(\S+)", line)
                if not match:
                    continue
                path = match.group(1)
                self.assertTrue(path.startswith(self.PREFIX), (name, path))
                local = os.path.join(DEPLOY, path[len(self.PREFIX):])
                self.assertTrue(os.path.isfile(local), (name, path))
                self.assertTrue(os.stat(local).st_mode & stat.S_IXUSR,
                                "%s is not executable" % local)
                checked += 1
        self.assertGreater(checked, 5)

    def test_provision_installs_every_unit_the_scripts_start(self):
        provision = read(NODE, "provision.sh")
        units = set(os.listdir(os.path.join(NODE, "systemd")))
        for timer in re.findall(r"(brainfreeze-\w+\.timer)", provision):
            self.assertIn(timer, units)
        self.assertIn("gemdb.service", units)
        self.assertIn("brainfreeze-app@.service", units)

    def test_the_scripts_are_executable(self):
        for name in ["startup.sh", "provision.sh"] + [
                os.path.join("bin", n) for n in os.listdir(os.path.join(NODE, "bin"))]:
            mode = os.stat(os.path.join(NODE, name)).st_mode
            self.assertTrue(mode & stat.S_IXUSR, "%s is not executable" % name)
        self.assertTrue(os.stat(os.path.join(DEPLOY, "deploy.sh")).st_mode
                        & stat.S_IXUSR)


class TheVMIsToldWhatItReads(unittest.TestCase):
    def test_every_attribute_the_scripts_read_is_in_the_template(self):
        template = read(TERRAFORM, "compute.tf")
        given = set(re.findall(r"^\s+(bf-[\w-]+)\s*=", template, re.M))
        read_ = set()
        for name in ("startup.sh", "provision.sh"):
            read_ |= set(re.findall(r"(?:attribute|metadata) (bf-[\w-]+)",
                                    read(NODE, name)))
        self.assertTrue(read_)
        self.assertEqual(read_ - given, set(),
                         "read on the VM but never set by Terraform")


if __name__ == "__main__":
    unittest.main()
