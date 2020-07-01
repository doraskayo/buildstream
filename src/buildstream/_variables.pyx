#
#  Copyright (C) 2020 Codethink Limited
#  Copyright (C) 2019 Bloomberg L.P.
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
#        Tristan Van Berkom <tristan.vanberkom@codethink.co.uk>
#        Daniel Silverstone <daniel.silverstone@codethink.co.uk>
#        Benjamin Schubert <bschubert@bloomberg.net>

import re
import sys
import itertools

from ._exceptions import LoadError
from .exceptions import LoadErrorReason
from .node cimport MappingNode, Node, ScalarNode, SequenceNode, ProvenanceInformation


# The Variables helper object will resolve the variable references in
# the given dictionary, expecting that any dictionary values which contain
# variable references can be resolved from the same dictionary.
#
# Each Element creates its own Variables instance to track the configured
# variable settings for the element.
#
# Args:
#     node (Node): A node loaded and composited with yaml tools
#
# Raises:
#     LoadError, if unresolved variables, or cycles in resolution, occur.
#
cdef class Variables:

    cdef dict _values  # The Value objects

    def __init__(self, MappingNode node):

        # Special case, if notparallel is specified in the variables for this
        # element, then override max-jobs to be 1.
        # Initialize it as a string as all variables are processed as strings.
        #
        if node.get_bool('notparallel', False):
            #
            # The MappingNode API will automatically convert this `str(1)`
            # into a ScalarNode, no need to manually create the ScalarNode here.
            #
            node['max-jobs'] = str(1)

        self._values = self._init_values(node)

    # __getitem__()
    #
    # Enables indexing access to variables.
    #
    # Args:
    #    name (str): The key
    #
    # Returns:
    #    (str): The value
    #
    def __getitem__(self, str name) -> str:
        return self._resolve(name, None)

    # __contains__()
    #
    # Implements syntaxes like `if "foo" in variables`
    #
    # Args:
    #    name (str): The key
    #
    # Returns:
    #    (bool): Whether the name exists as a key in this variables mapping
    #
    def __contains__(self, str name) -> bool:
        return name in self._values

    # __iter__()
    #
    # Implements the iterator interface so that we can iterate over the
    # Variables type, this also allows transformation of the Variables
    # type into a simple dictionary where the keys are the variable names
    # and the values are the fully resolve values.
    #
    # Returns:
    #    (Iterator[Tuple[str, str]]): The variable names and resolved values
    #
    def __iter__(self):
        return ValueIterator(self, self._values)

    # get()
    #
    # Expand definition of variable by name. If the variable is not
    # defined, it will return None instead of failing.
    #
    # Args:
    #   name (str): Name of the variable to expand
    #
    # Returns:
    #   (str|None): The expanded value for the variable or None variable was not defined.
    #
    cpdef str get(self, str name):
        try:
            return <str> self._resolve(name, None)
        except LoadError as e:
            if e.reason == LoadErrorReason.UNRESOLVED_VARIABLE:
                return None

    # expand()
    #
    # Expand all the variables found in the given Node, recursively.
    # This does the change in place, modifying the node. If you want to keep
    # the node untouched, you should use `node.clone()` beforehand
    #
    # Args:
    #   (Node): A node for which to substitute the values
    #
    cpdef expand(self, Node node):
        self._expand(node)

    # subst():
    #
    # Substitutes any variables in 'string' and returns the result.
    #
    # Args:
    #    (string): The string to substitute
    #
    # Returns:
    #    (string): The new string with any substitutions made
    #
    # Raises:
    #    LoadError, if the string contains unresolved variable references.
    #
    cpdef subst(self, ScalarNode node):
        cdef Value value = Value()
        cdef object dep_name_object
        cdef str dep_name

        value.init(node)

        for dep_name_object in value.dependencies():
            dep_name = <str> dep_name_object
            self._resolve(dep_name, node.get_provenance())

        return value.resolve(self._values)

    # check()
    #
    # Checks the variables for unresolved references
    #
    # Raises:
    #    (LoadError): If there are unresolved references, then a LoadError
    #                 with LoadErrorReason.UNRESOLVED_VARIABLE reason will
    #                 be raised.
    #
    cpdef check(self):

        # Resolve all variables.
        for key in self._values.keys():
            self._resolve(key, None)

    # _init_values()
    #
    # Here we initialize the Value() table, which contains
    # as of yet unresolved variables.
    #
    cdef dict _init_values(self, MappingNode node):
        cdef dict ret = {}
        cdef key_object
        cdef value_node_object
        cdef str key
        cdef ScalarNode value_node

        for key_object, value_object in node.items():
            key = <str> sys.intern(<str> key_object)
            value_node = <ScalarNode> value_object
            value = Value()
            value.init(value_node)
            ret[key] = value

        return ret

    # _expand()
    #
    # Internal implementation of Variables.expand()
    #
    # Args:
    #   (Node): A node for which to substitute the values
    #
    cdef _expand(self, Node node):
        if isinstance(node, ScalarNode):
            (<ScalarNode> node).value = self.subst(node)
        elif isinstance(node, SequenceNode):
            for entry in (<SequenceNode> node).value:
                self._expand(entry)
        elif isinstance(node, MappingNode):
            for entry in (<MappingNode> node).value.values():
                self._expand(entry)
        else:
            assert False, "Unknown 'Node' type"

    # _resolve()
    #
    # Helper to expand and cache a variable definition in the context of
    # the given dictionary of expansion strings.
    #
    # Args:
    #     name (str): Name of the variable to expand
    #     provenance (ProvenanceInformation): Whence this variable was refered from
    #
    # Returns:
    #     (str): The expanded value of variable
    #
    # Raises:
    #     (LoadError): In case there was any undefined variables or circular
    #                  references encountered when resolving the variable.
    #
    cdef str _resolve(self, str name, ProvenanceInformation provenance):
        cdef ResolutionStep step
        cdef ResolutionStep new_step
        cdef ResolutionStep this_step
        cdef Value iter_value
        cdef object iter_name_object
        cdef str iter_name
        cdef set iter_value_deps
        cdef str resolved_value

        # While iterating over the first loop, we collect all of the variable
        # dependencies, and perform all required validation.
        #
        # Each iteration processes a ResolutionStep object and has the possibility
        # to enque more ResolutionStep objects as a result.
        #
        cdef list deps = []
        cdef bint first_iteration = True

        step = ResolutionStep()
        step.init(None, { sys.intern(name) }, None)

        while step:
            # Keep a hold of the current overall step
            this_step = step
            step = step.prev

            # Check for circular dependencies
            this_step.check_circular(self._values)

            # For each dependency stemming from this provenance
            for iter_name_object in this_step.varnames:
                iter_name = <str> iter_name_object
                iter_value = self._get_checked_value(iter_name, this_step.referee, provenance)

                # Earliest return for an already resolved value
                #
                if first_iteration:
                    if iter_value._resolved is not None:
                        return iter_value.resolve(self._values)
                    first_iteration = False

                # Queue up this value to be resolved in the next loop
                if iter_value._resolved is None:
                    deps.append(iter_value)

                    # Queue up it's dependencies for resolution
                    iter_value_deps = iter_value.dependencies()
                    if iter_value_deps:
                        new_step = ResolutionStep()
                        new_step.init(iter_name, iter_value_deps, this_step)

                        # Link it to the end of the stack
                        new_step.prev = step
                        step = new_step

        # We've now constructed the dependencies queue such that
        # later dependencies are on the right, we can now safely peddle
        # backwards and the last (leftmost) resolved value is the one
        # we want to return.
        #
        while deps:
            iter_value = deps.pop()
            resolved_value = iter_value.resolve(self._values)

        return resolved_value

    # _get_checked_value()
    #
    # Fetches a value from the value table and raises a user
    # facing error if the value is undefined.
    #
    # Args:
    #    varname (str): The variable name to fetch
    #    referee (str): The variable name referring to `varname`, or None
    #    provenance (ProvenanceInformation): The provenance, incase referee is None.
    #
    # Returns:
    #   (Value): The Value for varname
    #
    # Raises:
    #   (LoadError): An appropriate error in case of undefined variables
    #
    cdef Value _get_checked_value(self, str varname, str referee, ProvenanceInformation provenance):
        cdef Value referee_value
        cdef str error_message

        #
        # Fetch the value and detect undefined references
        #
        try:
            return <Value> self._values[varname]
        except KeyError as e:

            # Either the provenance is the toplevel calling provenance,
            # or it is the provenance of the direct referee
            try:
                referee_value = self._values[referee]
            except KeyError:
                referee_value = None

            if referee_value:
                provenance = referee_value.provenance

            error_message = "Reference to undefined variable '{}'".format(varname)
            if provenance:
                error_message = "{}: {}".format(provenance, error_message)
            raise LoadError(error_message, LoadErrorReason.UNRESOLVED_VARIABLE) from e


# ResolutionStep()
#
# The context for a single iteration in variable resolution.
#
# This only exists for better performance than constructing
# and unpacking tuples.
#
cdef class ResolutionStep:
    cdef str referee
    cdef set varnames
    cdef ResolutionStep parent
    cdef ResolutionStep prev

    # init()
    #
    # Initialize this ResolutionStep
    #
    # Args:
    #    referee (str): The name of the referring variable
    #    varnames (set): A set of variable names which referee refers to.
    #    parent (ResolutionStep): The parent ResolutionStep
    #
    cdef init(self, str referee, set varnames, ResolutionStep parent):
        self.referee = referee
        self.varnames = varnames
        self.parent = parent
        self.prev = None

    # check_circular()
    #
    # Check for circular references in this step.
    #
    # Args:
    #    values (dict): The value dictionary for lookups
    #
    # Raises:
    #    (LoadError): Will raise a user facing LoadError with
    #                 LoadErrorReason.CIRCULAR_REFERENCE_VARIABLE in case
    #                 circular references were encountered.
    #
    cdef check_circular(self, dict values):
        cdef ResolutionStep step = self.parent
        while step:
            if self.referee is step.referee:
                self._raise_circular_reference_error(step, values)
            step = step.parent

    # _raise_circular_reference_error()
    #
    # Helper function to construct a full report and raise the circular reference error.
    #
    cdef _raise_circular_reference_error(self, ResolutionStep conflict, dict values):
        cdef list error_lines = []
        cdef ResolutionStep step = self
        cdef Value value
        cdef str referee

        while step is not conflict:
            if step.parent:
                referee = step.parent.referee
            else:
                referee = self.referee
            value = values[referee]

            error_lines.append("{}: Variable '{}' refers to variable '{}'".format(value.provenance, referee, step.referee))
            step = step.parent

        raise LoadError("Circular dependency detected on variable '{}'".format(self.referee),
                        LoadErrorReason.CIRCULAR_REFERENCE_VARIABLE,
                        detail="\n".join(reversed(error_lines)))


# ValuePart()
#
# Represents a part of a value (a string and an indicator
# of whether the string is a variable or not).
#
# This only exists for better performance than constructing
# and unpacking tuples.
#
# Args:
#    text (str): The text of this part
#    is_variable (bint): True if the text is a variable, False if it's literal
#
cdef class ValuePart:
    cdef str text
    cdef bint is_variable
    cdef ValuePart next_part

    cdef init(self, str text, bint is_variable):
        self.text = text
        self.is_variable = is_variable
        self.next_part = None


cdef EMPTY_SET = set()

# Value():
#
# Represents a variable value
#
cdef class Value:
    cdef ProvenanceInformation provenance
    cdef ValueClass _value_class
    cdef str _resolved

    # init()
    #
    # Initialize the Value
    #
    # Args:
    #    node (ScalarNode): The node representing this value.
    #
    cdef init(self, ScalarNode node):

        # Public
        self.provenance = node.get_provenance()

        # Private
        self._value_class = self._load_value_class(node.as_str())
        self._resolved = None

    # resolve()
    #
    # Resolve the value of this variable, this function expects
    # all dependency values to already be resolved, otherwise
    # it will fail due to an undefined variable.
    #
    # Args:
    #    values (dict): The full value table for resolving dependencies
    #
    # Returns:
    #    (str): The resolved value
    #
    cdef str resolve(self, dict values):
        cdef str dep_name
        cdef Value part_var
        cdef ValuePart part
        cdef object part_object
        cdef list parts = []

        if self._resolved is None:
            part = self._value_class.parts

            while part:
                if part.is_variable:
                    part_var = <Value> values[part.text]
                    parts.append(part_var._resolved)
                else:
                    parts.append(part.text)

                part = part.next_part

            self._resolved = "".join(parts)

        return self._resolved

    # dependencies()
    #
    # Returns the set of dependency variable names
    #
    # Returns:
    #    (set): The set of variable names which this ValueClass depends on, or None.
    #
    cdef set dependencies(self):
        if self._resolved is None:
            return self._value_class.variable_names

        # If we're already resolved, we don't have any dependencies anymore
        return <set> EMPTY_SET

    # _load_value_class()
    #
    # Load the ValueClass for this Value, possibly reusing
    # a pre-cached ValueClass if one exists.
    #
    # Args:
    #    string (str): The string to parse
    #
    # Returns:
    #    (ValueClass): The ValueClass object
    #
    cdef ValueClass _load_value_class(self, str string):
        cdef ValueClass ret
        cdef str internal_string = sys.intern(string)

        try:
            ret = VALUE_CLASS_TABLE[internal_string]
        except KeyError:
            ret = ValueClass()
            ret.init(internal_string)
            VALUE_CLASS_TABLE[internal_string] = ret

        return ret


# Global cache of all ValueClass objects ever instantiated.
#
# While many elements share exactly the same ValueClasses, they
# all have their own Value instances and can resolve to different
# string values.
#
# Holding on to this avoids ever parsing the same value strings
# more than once.
#
cdef dict VALUE_CLASS_TABLE = {}


#
# The regular expression used for parsing ValueClass strings.
#
# Note that Variable names are allowed to have alphanumeric characters
# and dashes and underscores, but cannot start with a dash, underscore
# or a digit.
#
VALUE_CLASS_PARSE_EXPANSION = re.compile(r"\%\{([a-zA-Z][a-zA-Z0-9_-]*)\}")


# ValueClass()
#
# A class representing a broken down parse of a value.
#
cdef class ValueClass:
    #
    # Public
    #
    cdef set variable_names  # A set of variable names
    cdef ValuePart parts  # The linked list of ValuePart objects

    # init():
    #
    # Initialize the ValueClass()
    #
    # Args:
    #    string (str): The string which can contain variables
    #
    cdef init(self, str string):
        self.variable_names = set()
        self.parts = None
        self._parse_string(string)

    # _parse_string()
    #
    # Parse the string for this ValueClass, breaking it down into
    # the parts list, which is an ordered list of literal values
    # and variable names, which when resolved, can be joined into
    # the resolved value.
    #
    cdef _parse_string(self, str string):

        # This use of this regex turns a string like
        # "foo %{bar} baz" into a list ["foo ", "bar", " baz"]
        #
        # This split has special properties in that it will
        # return empty strings, and even/odd members of the
        # returned list are meaningful.
        #
        # The even number indices are slices of the text which
        # did not match the regular expression, while the odd
        # number indices represent variable names, with the "%{}"
        # portions stripped away.
        #
        # In case you are still wondering: Yes. This is very, very weird.
        #
        # What do you expect ? These are regular expressions after all,
        # they are *supposed* to be weird.
        #
        cdef list splits = VALUE_CLASS_PARSE_EXPANSION.split(string)
        cdef object split_object
        cdef str split
        cdef Py_ssize_t split_idx = 0
        cdef bint is_variable
        cdef ValuePart part
        cdef ValuePart last_part = None

        #
        # Collect the weird regex return value into something
        # more comprehensible.
        #

        for split_object in splits:
            split = <str> split_object
            if split:

                # Use an intern for the part, this will not only
                # save memory but it will speed up lookups in the
                # case that the part in question is used to lookup
                # variable values.
                split = <str> sys.intern(split)

                if (split_idx % 2) == 0:
                    is_variable = False
                else:
                    is_variable = True
                    self.variable_names.add(split)

                part = ValuePart()
                part.init(split, is_variable)
                if last_part:
                    last_part.next_part = part
                else:
                    self.parts = part
                last_part = part

            split_idx += 1


# ValueIterator()
#
# Iterator for all flatten variables.
#
# Used by Variables.__iter__
#
cdef class ValueIterator:
    cdef Variables _variables
    cdef object _iter

    def __cinit__(self, Variables variables, dict values):
        self._variables = variables
        self._iter = iter(values)

    def __iter__(self):
        return self

    def __next__(self):
        name = next(self._iter)
        return name, self._variables[name]
