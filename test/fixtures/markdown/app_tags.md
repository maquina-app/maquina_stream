Models emit XML-ish tags that mean something to the application rather than to
markdown. None of these are registered, so none of them may survive as markup —
but every character between them must still reach a block.

<thinking>
First I consider the problem.

Then I consider the alternative, at length, over a second paragraph that the
splitter has to keep.
</thinking>

<answer>
Here is the answer.
</answer>

An inline one: the model wrote <citation>source 3</citation> in the middle of a
sentence, and the sentence has to survive it.

<tool_call name="search" args='{"q":"maquina"}'>
{"query": "maquina stream"}
</tool_call>

A tag that never closes at all:

<thinking>
Reasoning that the model forgot to terminate.
