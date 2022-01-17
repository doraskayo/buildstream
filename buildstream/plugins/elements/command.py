#
#  Copyright (C) 2021 Dor Askayo
#
#  This program is free software; you can redistribute it and/or
#  modify it under the terms of the GNU Lesser General Public
#  License as published by the Free Software Foundation; either
#  version 2 of the License, or (at your option) any later version.
#
#  This library is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	 See the GNU
#  Lesser General Public License for more details.
#
#  You should have received a copy of the GNU Lesser General Public
#  License along with this library. If not, see <http://www.gnu.org/licenses/>.
#
#  Authors:
#        Dor Askayo <dor.askayo@gmail.com>

"""
command - Run a command to create output
=====================================
This element allows one to execute a single command to mutate the
input and create some output.

.. note::

   Command elements may only specify build dependencies. See
   :ref:`the format documentation <format_dependencies>` for more
   detail on specifying dependencies.

The default configuration and possible options are as such:
  .. literalinclude:: ../../../buildstream/plugins/elements/command.yaml
     :language: yaml
"""

from buildstream import ScriptElement, ElementError


# Element implementation for the 'command' kind.
class CommandElement(ScriptElement):
    # pylint: disable=attribute-defined-outside-init

    def configure(self, node):
        for n in self.node_get_member(node, list, 'layout', []):
            dst = self.node_subst_member(n, 'destination')
            elm = self.node_subst_member(n, 'element', None)
            self.layout_add(elm, dst)

        self.node_validate(node, [
            'command', 'root-read-only', 'layout'
        ])

        cmd = self.node_subst_member(node, "command")
        self.add_commands("command", [cmd])

        self.set_work_dir()
        self.set_install_root()
        self.set_root_read_only(self.node_get_member(node, bool,
                                                     'root-read-only', False))

    def assemble(self, sandbox):
        for groupname, commands in self.get_commands().items():
            for cmd in commands:
                with self.timed_activity("Running command", detail=cmd):
                    exitcode = sandbox.run([cmd],
                                           SandboxFlags.ROOT_READ_ONLY if self.get_root_read_only() else 0)
                    if exitcode != 0:
                        raise ElementError("Command '{}' failed with exitcode {}".format(cmd, exitcode))

        # Return where the result can be collected from
        return self.get_install_root()


# Plugin entry point
def setup():
    return CommandElement
