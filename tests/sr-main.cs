// Entry point for tests\session-review-test.ps1 only: compiled together with dash\src\*.cs (csc /main:IRDash.SrMain) into a
// throw-away exe in %TEMP%, so the Session Review data can be produced offline from copies of old .ibt files without
// touching dash\src\irdash.cs or the deployed irdash.exe.
namespace IRDash
{
    static class SrMain
    {
        static int Main(string[] args) { return Analysis.SrCli(args); }
    }
}
