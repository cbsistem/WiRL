(*
  Copyright 2015-2016, WiRL - REST Library

  Home: https://github.com/WiRL-library

*)
unit WiRL.Core.Engine;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.SyncObjs, System.Diagnostics, System.Rtti,

  WiRL.Core.Classes,
  WiRL.Rtti.Utils,
  WiRL.Core.MediaType,
  WiRL.Core.Exceptions,
  WiRL.Core.Registry,
  WiRL.Core.Application,
  WiRL.Core.URL,
  WiRL.Core.Request,
  WiRL.Core.Response,
  WiRL.Core.Attributes,
  WiRL.http.Filters;

{$M+}

type
  TWiRLEngine = class;

  IWiRLHandleListener = interface
  ['{5C4F450A-1264-449E-A400-DA6C2714FD23}']
  end;

  // Request is a valid resource
  IWiRLHandleRequestEventListener = interface(IWiRLHandleListener)
  ['{969EF9FA-7887-47E6-8996-8B0D6326668E}']
    procedure BeforeHandleRequest(const ASender: TWiRLEngine; const AApplication: TWiRLApplication);
    procedure AfterHandleRequest(const ASender: TWiRLEngine; const AApplication: TWiRLApplication; const AStopWatch: TStopWatch);
  end;

  // Any request even outside the BasePath
  IWiRLHandleRequestEventListenerEx = interface(IWiRLHandleListener)
  ['{45809922-03DB-4B4D-8E2C-64D931978A94}']
    procedure BeforeRequestStart(const ASender: TWiRLEngine; var Handled: Boolean);
    procedure AfterRequestEnd(const ASender: TWiRLEngine; const AStopWatch: TStopWatch);
  end;

  IWiRLHandleExceptionListener = interface(IWiRLHandleListener)
  ['{BDE72935-F73B-4378-8755-01D18EC566B2}']
    procedure HandleException(const ASender: TWiRLEngine; const AApplication: TWiRLApplication; E: Exception);
  end;

  TWiRLEngine = class
  private
    class threadvar FRequest: TWiRLRequest;
    class threadvar FResponse: TWiRLResponse;
    class threadvar FURL: TWiRLURL;
  private
    class var FServerFileName: string;
    class var FServerDirectory: string;
    class function GetServerDirectory: string; static;
    class function GetServerFileName: string; static;
  private
    FRttiContext: TRttiContext;
    FApplications: TWiRLApplicationDictionary;
    FSubscribers: TList<IWiRLHandleListener>;
    FCriticalSection: TCriticalSection;
    FBasePath: string;
    FPort: Integer;
    FThreadPoolSize: Integer;
    FName: string;

    function GetURL: TWiRLURL;
    function GetRequest: TWiRLRequest;
    function GetResponse: TWiRLResponse;

    // Filter handling
    procedure ApplyPreMatchingFilters;

  protected
    procedure DoBeforeHandleRequest(const AApplication: TWiRLApplication); virtual;
    procedure DoAfterHandleRequest(const AApplication: TWiRLApplication; const AStopWatch: TStopWatch); virtual;
    function DoBeforeRequestStart() :Boolean; virtual;
    procedure DoAfterRequestEnd(const AStopWatch: TStopWatch); virtual;
    procedure DoHandleException(const AApplication: TWiRLApplication; E: Exception); virtual;
  public
    constructor Create;
    destructor Destroy; override;

    procedure HandleRequest(ARequest: TWiRLRequest; AResponse: TWiRLResponse);

    function AddApplication(const ABasePath: string): TWiRLApplication; overload; virtual;
    function AddApplication(const AName, ABasePath: string; const AResources: array of string): TWiRLApplication; overload; virtual; deprecated;

    function AddSubscriber(const ASubscriber: IWiRLHandleListener): TWiRLEngine;
    function RemoveSubscriber(const ASubscriber: IWiRLHandleListener): TWiRLEngine;

    procedure EnumerateApplications(const ADoSomething: TProc<string, TWiRLApplication>);

    function SetName(const AName: string): TWiRLEngine;
    function SetBasePath(const ABasePath: string): TWiRLEngine;
    function SetPort(APort: Integer): TWiRLEngine;
    function SetThreadPoolSize(AThreadPoolSize: Integer): TWiRLEngine;

    property Applications: TWiRLApplicationDictionary read FApplications;
    property BasePath: string read FBasePath write FBasePath;
    property Name: string read FName write FName;
    property Port: Integer read FPort write FPort;
    property ThreadPoolSize: Integer read FThreadPoolSize write FThreadPoolSize;

    property CurrentRequest: TWiRLRequest read GetRequest;
    property CurrentResponse: TWiRLResponse read GetResponse;
    property CurrentURL: TWiRLURL read GetURL;

    class property ServerFileName: string read GetServerFileName;
    class property ServerDirectory: string read GetServerDirectory;
  end;

implementation

uses
  System.StrUtils,
  WiRL.Core.Utils;

function TWiRLEngine.AddApplication(const AName, ABasePath: string;
  const AResources: array of string): TWiRLApplication;
begin
  Result := Self
    .AddApplication(ABasePath)
    .SetName(AName)
    .SetResources(AResources);
end;

function TWiRLEngine.AddApplication(const ABasePath: string): TWiRLApplication;
begin
  Result := TWiRLApplication.Create(Self);
  Result.SetBasePath(ABasePath);
  try
    Applications.Add(TWiRLURL.CombinePath([BasePath, ABasePath]), Result);
  except
    Result.Free;
    raise
  end;
end;

function TWiRLEngine.AddSubscriber(const ASubscriber: IWiRLHandleListener): TWiRLEngine;
begin
  FSubscribers.Add(ASubscriber);
  Result := Self;
end;

procedure TWiRLEngine.ApplyPreMatchingFilters;
var
  LRequestFilter: IWiRLContainerRequestFilter;
begin
  TWiRLFilterRegistry.Instance.FetchRequestFilter(True,
    procedure (ConstructorInfo :TWiRLFilterConstructorInfo)
    begin
      // The check doesn't have any sense but I must use SUPPORT and I hate using it without a check
      if not Supports(ConstructorInfo.ConstructorFunc(), IWiRLContainerRequestFilter, LRequestFilter) then
        raise EWiRLNotImplementedException.Create(
          Format('Request Filter [%s] does not implement requested interface [IWiRLContainerRequestFilter]', [ConstructorInfo.TypeTClass.ClassName]),
          Self.ClassName, 'ApplyPreMatchingFilters'
        );
      LRequestFilter.Filter(FRequest);
    end
  );
end;

constructor TWiRLEngine.Create;
begin
  FRttiContext := TRttiContext.Create;
  FApplications := TWiRLApplicationDictionary.Create([doOwnsValues]);
  FCriticalSection := TCriticalSection.Create;
  FSubscribers := TList<IWiRLHandleListener>.Create;
  FPort := 8080;
  FThreadPoolSize := 50;
  FBasePath := '/rest';
  FName := 'WiRL Engine';

  inherited Create;
end;

destructor TWiRLEngine.Destroy;
begin
  FCriticalSection.Free;
  FApplications.Free;
  FSubscribers.Free;
  inherited;
end;

procedure TWiRLEngine.DoAfterHandleRequest(const AApplication: TWiRLApplication;
  const AStopWatch: TStopWatch);
var
  LSubscriber: IWiRLHandleListener;
  LHandleRequestEventListener: IWiRLHandleRequestEventListener;
begin
  for LSubscriber in FSubscribers do
    if Supports(LSubscriber, IWiRLHandleRequestEventListener, LHandleRequestEventListener) then
      LHandleRequestEventListener.AfterHandleRequest(Self, AApplication, AStopWatch);
end;

procedure TWiRLEngine.DoAfterRequestEnd(const AStopWatch: TStopWatch);
var
  LSubscriber: IWiRLHandleListener;
  LHandleRequestEventListenerEx: IWiRLHandleRequestEventListenerEx;
begin
  for LSubscriber in FSubscribers do
    if Supports(LSubscriber, IWiRLHandleRequestEventListenerEx, LHandleRequestEventListenerEx) then
      LHandleRequestEventListenerEx.AfterRequestEnd(Self, AStopWatch);
end;

procedure TWiRLEngine.DoBeforeHandleRequest(const AApplication: TWiRLApplication);
var
  LSubscriber: IWiRLHandleListener;
  LHandleRequestEventListener: IWiRLHandleRequestEventListener;
begin
  for LSubscriber in FSubscribers do
    if Supports(LSubscriber, IWiRLHandleRequestEventListener, LHandleRequestEventListener) then
      LHandleRequestEventListener.BeforeHandleRequest(Self, AApplication);
end;

function TWiRLEngine.DoBeforeRequestStart(): Boolean;
var
  LSubscriber: IWiRLHandleListener;
  LHandleRequestEventListenerEx: IWiRLHandleRequestEventListenerEx;
begin
  Result := False;
  for LSubscriber in FSubscribers do
    if Supports(LSubscriber, IWiRLHandleRequestEventListenerEx, LHandleRequestEventListenerEx) then
    begin
      LHandleRequestEventListenerEx.BeforeRequestStart(Self, Result);
      if Result then
        Break;
    end;
end;

procedure TWiRLEngine.DoHandleException(const AApplication: TWiRLApplication;
  E: Exception);
var
  LSubscriber: IWiRLHandleListener;
  LHandleExceptionListener: IWiRLHandleExceptionListener;
begin
  if E is EWiRLWebApplicationException then
  begin
    FResponse.StatusCode := EWiRLWebApplicationException(E).Status;
    FResponse.Content := EWiRLWebApplicationException(E).ToJSON;
    FResponse.ContentType := TMediaType.APPLICATION_JSON;
  end
  else if E is Exception then
  begin
    FResponse.StatusCode := 500;
    FResponse.Content := EWiRLWebApplicationException.ExceptionToJSON(E);
    FResponse.ContentType := TMediaType.APPLICATION_JSON;
  end;

  for LSubscriber in FSubscribers do
    if Supports(LSubscriber, IWiRLHandleExceptionListener, LHandleExceptionListener) then
      LHandleExceptionListener.HandleException(Self, AApplication, E);
end;

procedure TWiRLEngine.EnumerateApplications(
  const ADoSomething: TProc<string, TWiRLApplication>);
var
  LPair: TPair<string, TWiRLApplication>;
begin
  if Assigned(ADoSomething) then
  begin
    FCriticalSection.Enter;
    try
      for LPair in FApplications do
        ADoSomething(LPair.Key, LPair.Value);
    finally
      FCriticalSection.Leave;
    end;
  end;
end;

procedure TWiRLEngine.HandleRequest(ARequest: TWiRLRequest; AResponse: TWiRLResponse);
var
  LApplication: TWiRLApplication;
  LApplicationPath: string;
  LStopWatch: TStopWatch;
  LStopWatchEx: TStopWatch;
begin
  FURL := nil;
  try
    LApplication := nil;
    LStopWatchEx := TStopwatch.StartNew;
    FRequest := ARequest;
    FResponse := AResponse;
    try
      ApplyPreMatchingFilters;
      if not DoBeforeRequestStart() then
      begin
        FURL := TWiRLURL.Create(ARequest); // The object must exists until the end of this procedure
        LApplicationPath := TWiRLURL.CombinePath([FURL.PathTokens[0]]);
        if (BasePath <> '') and (BasePath <> TWiRLURL.URL_PATH_SEPARATOR) then
        begin
          if not FURL.MatchPath(BasePath + TWiRLURL.URL_PATH_SEPARATOR) then
            raise EWiRLNotFoundException.Create(
              Format('Requested URL [%s] does not match base engine URL [%s]', [FURL.URL, BasePath]),
              Self.ClassName, 'HandleRequest'
            );

          LApplicationPath := TWiRLURL.CombinePath([FURL.PathTokens[0], FURL.PathTokens[1]]);
        end;

        if FApplications.TryGetValue(LApplicationPath, LApplication) then
        begin
          FURL.BasePath := LApplicationPath;
          DoBeforeHandleRequest(LApplication);
          LApplication.ApplyRequestFilters;
          LStopWatch := TStopwatch.StartNew;
          try
            LApplication.HandleRequest(ARequest, AResponse, FURL);
          finally
            LStopWatch.Stop;
          end;
          DoAfterHandleRequest(LApplication, LStopWatch);
        end
        else
          raise EWiRLNotFoundException.Create(
            Format('Application [%s] not found, please check the URL [%s]', [LApplicationPath, FURL.URL]),
            Self.ClassName, 'HandleRequest'
          );
      end;
    except
      on E: Exception do
        DoHandleException(LApplication, E);
    end;
    LStopWatchEx.Stop;

    try
      if Assigned(LApplication) then
        LApplication.ApplyResponseFilters;
    except
      on E: Exception do
      begin
        DoHandleException(LApplication, E);
      end
    end;

    DoAfterRequestEnd(LStopWatchEx);
  finally
    FreeAndNil(FURL);
  end;
end;

function TWiRLEngine.RemoveSubscriber(const ASubscriber: IWiRLHandleListener): TWiRLEngine;
begin
  FSubscribers.Remove(ASubscriber);
  Result := Self;
end;

function TWiRLEngine.SetBasePath(const ABasePath: string): TWiRLEngine;
begin
  if StartsText('/', ABasePath) then
    FBasePath := ABasePath
  else
    FBasePath := '/' + ABasePath;

  Result := Self;
end;

function TWiRLEngine.SetName(const AName: string): TWiRLEngine;
begin
  FName := AName;
  Result := Self;
end;

function TWiRLEngine.SetPort(APort: Integer): TWiRLEngine;
begin
  FPort := APort;
  Result := Self;
end;

function TWiRLEngine.SetThreadPoolSize(AThreadPoolSize: Integer): TWiRLEngine;
begin
  FThreadPoolSize := AThreadPoolSize;
  Result := Self;
end;

function TWiRLEngine.GetRequest: TWiRLRequest;
begin
  Result := FRequest;
end;

function TWiRLEngine.GetResponse: TWiRLResponse;
begin
  Result := FResponse;
end;

class function TWiRLEngine.GetServerDirectory: string;
begin
  if FServerDirectory = '' then
    FServerDirectory := ExtractFilePath(ServerFileName);
  Result := FServerDirectory;
end;

class function TWiRLEngine.GetServerFileName: string;
begin
  if FServerFileName = '' then
    FServerFileName := GetModuleName(MainInstance);
  Result := FServerFileName;
end;

function TWiRLEngine.GetURL: TWiRLURL;
begin
  Result := FURL;
end;

end.
