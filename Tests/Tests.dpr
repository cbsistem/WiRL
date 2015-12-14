(*
  Copyright 2015, MARS - REST Library

  Home: https://github.com/MARS-library

*)
program Tests;

uses
  TestInsight.DUnit,
  ServerTests in 'ServerTests.pas',
  Tests.Authorization in 'Tests.Authorization.pas',
  Token.Resource.Standard in 'Resources\Token.Resource.Standard.pas',
  Authorization.Resource.Simple in 'Resources\Authorization.Resource.Simple.pas';

begin
  RunRegisteredTests;
end.