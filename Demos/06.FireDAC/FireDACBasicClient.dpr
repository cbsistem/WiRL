(*
  Copyright 2015, WiRL - REST Library

  Home: https://github.com/WiRL-library

*)
program FireDACBasicClient;

uses
  System.StartUpCopy,
  FMX.Forms,
  Forms.Main in 'Forms.Main.pas' {Form1};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.
