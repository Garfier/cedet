/* What the SPP replace file would looklike with MACROS replaced.
 */

/* TEST: The EMU keyword doesn't screw up the function defn. */
char parse_around_emu ()
{
}

/* TEST: A simple word can be replaced in a definition. */
float returnanfloat()
{
}

/* TEST: Punctuation an be replaced in a definition. */
int foo::bar ()
{
}

/* TEST: Multiple lexical characters in a definition */
int mysuper::baz ()
{
}

/* TEST: Macro replacement. */
int increment (int in) {
  return in+1;
}

/* TEST: Macro replacement with complex args */
int myFcn1 ();

int myFcn2 (int a, int b);
int myFcn3 (int a, int b);

/* TEST: Multiple args to a macro. */
struct ma_struct { int moose; int penguin; int emu; };

/* TEST: Not a macro with args, but close. */
int not_with_args_fcn (moose)
{
}

/* TEST: Macro w/ args, but no body. */
