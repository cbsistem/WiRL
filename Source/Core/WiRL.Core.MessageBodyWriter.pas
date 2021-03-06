(*
  Copyright 2015-2016, WiRL - REST Library

  Home: https://github.com/WiRL-library

*)
unit WiRL.Core.MessageBodyWriter;

{$I WiRL.inc}

interface

uses
  System.Classes, System.SysUtils, System.Rtti,
  System.Generics.Defaults, System.Generics.Collections,
  WiRL.Core.Singleton,
  WiRL.Core.MediaType,
  WiRL.Core.Declarations,
  WiRL.Core.Classes,
  WiRL.Core.Attributes;

type
  IMessageBodyWriter = interface
  ['{C22068E1-3085-482D-9EAB-4829C7AE87C0}']
    procedure WriteTo(const AValue: TValue; const AAttributes: TAttributeArray;
      AMediaType: TMediaType; AResponseHeaders: TStrings; AOutputStream: TStream);
  end;

  TIsWritableFunction = reference to function(AType: TRttiType;
    const AAttributes: TAttributeArray; AMediaType: string): Boolean;
  TGetAffinityFunction = reference to function(AType: TRttiType;
    const AAttributes: TAttributeArray; AMediaType: string): Integer;

  TEntryInfo = record
    _RttiType: TRttiType;
    RttiName: string;
    CreateInstance: TFunc<IMessageBodyWriter>;
    IsWritable: TIsWritableFunction;
    GetAffinity: TGetAffinityFunction;
  end;

  TWiRLMessageBodyRegistry = class
  private
    type
      TWiRLMessageBodyRegistrySingleton = TWiRLSingleton<TWiRLMessageBodyRegistry>;
  private
    FRegistry: TList<TEntryInfo>;
    FRttiContext: TRttiContext;
    class function GetInstance: TWiRLMessageBodyRegistry; static; inline;
  protected
    function GetProducesMediaTypes(const AObject: TRttiObject): TMediaTypeList;
  public
    constructor Create;
    destructor Destroy; override;

    procedure RegisterWriter(
      const ACreateInstance: TFunc<IMessageBodyWriter>;
      const AIsWritable: TIsWritableFunction;
      const AGetAffinity: TGetAffinityFunction;
      AWriterRttiType: TRttiType); overload;

    procedure RegisterWriter(
      const AWriterClass: TClass;
      const AIsWritable: TIsWritableFunction;
      const AGetAffinity: TGetAffinityFunction); overload;

    procedure RegisterWriter(const AWriterClass: TClass; const ASubjectClass: TClass;
      const AGetAffinity: TGetAffinityFunction); overload;

    procedure RegisterWriter<T: class>(const AWriterClass: TClass); overload;

    procedure FindWriter(const AMethod: TRttiMethod; const AAccept: string;
      out AWriter: IMessageBodyWriter; out AMediaType: TMediaType);

    procedure Enumerate(const AProc: TProc<TEntryInfo>);

    class property Instance: TWiRLMessageBodyRegistry read GetInstance;
    class function GetDefaultClassAffinityFunc<T: class>: TGetAffinityFunction;

    const AFFINITY_HIGH = 30;
    const AFFINITY_LOW = 10;
    const AFFINITY_VERY_LOW = 1;
    const AFFINITY_ZERO = 0;
  end;

implementation

uses
  WiRL.Core.Utils,
  WiRL.Rtti.Utils;

{ TWiRLMessageBodyRegistry }

constructor TWiRLMessageBodyRegistry.Create;
begin
  TWiRLMessageBodyRegistrySingleton.CheckInstance(Self);

  inherited Create;

  FRegistry := TList<TEntryInfo>.Create;
  FRttiContext := TRttiContext.Create;
end;

destructor TWiRLMessageBodyRegistry.Destroy;
begin
  FRegistry.Free;
  inherited;
end;

procedure TWiRLMessageBodyRegistry.Enumerate(const AProc: TProc<TEntryInfo>);
var
  LEntry: TEntryInfo;
begin
  for LEntry in FRegistry do
    AProc(LEntry);
end;

procedure TWiRLMessageBodyRegistry.FindWriter(const AMethod: TRttiMethod;
  const AAccept: string;
  out AWriter: IMessageBodyWriter; out AMediaType: TMediaType);
var
  LWriterEntry: TEntryInfo;
  LFound: Boolean;
  LCandidateAffinity: Integer;
  LCandidate: TEntryInfo;
  LWriterRttiType: TRttiType;
  LAcceptParser: TAcceptParser;

  LAcceptMediaTypes, LWriterMediaTypes: TMediaTypeList;
  LMethodProducesMediaTypes: TMediaTypeList;
  LAllowedMediaTypes: TArray<string>;
  LMediaTypes: TArray<string>;
  LMediaType: string;
  LCandidateMediaType: string;
  LCandidateQualityFactor: Double;
begin
  AWriter := nil;
  AMediaType := nil;
  LFound := False;
  LCandidateAffinity := -1;
  LCandidateMediaType := '';
  LCandidateQualityFactor := -1;
  if not Assigned(AMethod.ReturnType) then
    Exit; // no serialization (it's a procedure!)


  // consider client's Accept
  LAcceptParser := TAcceptParser.Create(AAccept);
  try
    LAcceptMediaTypes := LAcceptParser.MediaTypeList;

    // consider method's Produces
    LMethodProducesMediaTypes := GetProducesMediaTypes(AMethod);
    try
      if LMethodProducesMediaTypes.Count > 0 then
        LAllowedMediaTypes := TMediaTypeList.Intersect(LAcceptMediaTypes, LMethodProducesMediaTypes)
      else
        LAllowedMediaTypes := LAcceptMediaTypes.ToArrayOfString;

        if (Length(LAllowedMediaTypes) = 0)
          or ((Length(LAllowedMediaTypes) = 1) and (LAllowedMediaTypes[0] = TMediaType.WILDCARD))
        then // defaults
        begin
          if LMethodProducesMediaTypes.Count > 0 then
            LAllowedMediaTypes := LMethodProducesMediaTypes.ToArrayOfString
          else
          begin
            SetLength(LAllowedMediaTypes, 2);
            LAllowedMediaTypes[0] := TMediaType.APPLICATION_JSON;
            LAllowedMediaTypes[1] := TMediaType.WILDCARD;
          end;
        end;

        // collect compatible writers
        for LWriterEntry in FRegistry do
        begin
          LWriterRttiType := FRttiContext.FindType(LWriterEntry.RttiName);
          LWriterMediaTypes := GetProducesMediaTypes(LWriterRttiType);
          try
            if LWriterMediaTypes.Contains(TMediaType.WILDCARD) then
              LMediaTypes := LAllowedMediaTypes
            else
              LMediaTypes := TMediaTypeList.Intersect(LAllowedMediaTypes, LWriterMediaTypes);
            for LMediaType in LMediaTypes do
              if LWriterEntry.IsWritable(AMethod.ReturnType, AMethod.GetAttributes, LMediaType) then
              begin
                if not LFound
                   or (
                     (LCandidateAffinity < LWriterEntry.GetAffinity(AMethod.ReturnType, AMethod.GetAttributes, LMediaType))
                     or (LCandidateQualityFactor < LAcceptMediaTypes.GetQualityFactor(LMediaType))
                   )
                then
                begin
                  LCandidate := LWriterEntry;
                  LCandidateAffinity := LCandidate.GetAffinity(AMethod.ReturnType, AMethod.GetAttributes, LMediaType);
                  LCandidateMediaType := LMediaType;
                  LCandidateQualityFactor := LAcceptMediaTypes.GetQualityFactor(LMediaType);
                  LFound := True;
                end;
              end;
          finally
            LWriterMediaTypes.Free;
          end;
        end;

        if LFound then
        begin
          AWriter := LCandidate.CreateInstance();
          AMediaType := TMediaType.Create(LCandidateMediaType);
        end;
    finally
      LMethodProducesMediaTypes.Free;
    end;
  finally
    LAcceptParser.Free;
  end;
end;

class function TWiRLMessageBodyRegistry.GetDefaultClassAffinityFunc<T>: TGetAffinityFunction;
begin
  Result :=
    function (AType: TRttiType; const AAttributes: TAttributeArray; AMediaType: string): Integer
    begin
      if Assigned(AType) and TRttiHelper.IsObjectOfType<T>(AType, False) then
        Result := 100
      else if Assigned(AType) and TRttiHelper.IsObjectOfType<T>(AType) then
        Result := 99
      else
        Result := 0;
    end
end;

class function TWiRLMessageBodyRegistry.GetInstance: TWiRLMessageBodyRegistry;
begin
  Result := TWiRLMessageBodyRegistrySingleton.Instance;
end;

function TWiRLMessageBodyRegistry.GetProducesMediaTypes(
  const AObject: TRttiObject): TMediaTypeList;
var
  LList: TMediaTypeList;
begin
  LList := TMediaTypeList.Create;

  TRttiHelper.ForEachAttribute<ProducesAttribute>(AObject,
    procedure (AProduces: ProducesAttribute)
    begin
      LList.Add( TMediaType.Create(AProduces.Value) );
    end
  );

  Result := LList;
end;

procedure TWiRLMessageBodyRegistry.RegisterWriter(const AWriterClass: TClass;
  const AIsWritable: TIsWritableFunction; const AGetAffinity: TGetAffinityFunction);
begin
  RegisterWriter(
    function : IMessageBodyWriter
    var
      LInstance: TObject;
    begin
      LInstance := AWriterClass.Create;
      if not Supports(LInstance, IMessageBodyWriter, Result) then
        raise Exception.Create('Interface IMessageBodyWriter not implemented');
    end,
    AIsWritable,
    AGetAffinity,
    TRttiContext.Create.GetType(AWriterClass)
  );
end;

procedure TWiRLMessageBodyRegistry.RegisterWriter(const AWriterClass,
  ASubjectClass: TClass; const AGetAffinity: TGetAffinityFunction);
begin
  RegisterWriter(
    AWriterClass,
    function (AType: TRttiType; const AAttributes: TAttributeArray; AMediaType: string): Boolean
    begin
      Result := Assigned(AType) and TRttiHelper.IsObjectOfType(AType, ASubjectClass);
    end,
    AGetAffinity
  );
end;

procedure TWiRLMessageBodyRegistry.RegisterWriter<T>(const AWriterClass: TClass);
begin
  RegisterWriter(
    AWriterClass,
    function (AType: TRttiType; const AAttributes: TAttributeArray; AMediaType: string): Boolean
    begin
      Result := Assigned(AType) and TRttiHelper.IsObjectOfType<T>(AType);
    end,
    Self.GetDefaultClassAffinityFunc<T>()
  );
end;

procedure TWiRLMessageBodyRegistry.RegisterWriter(
  const ACreateInstance: TFunc<IMessageBodyWriter>;
  const AIsWritable: TIsWritableFunction;
  const AGetAffinity: TGetAffinityFunction;
  AWriterRttiType: TRttiType);
var
  LEntryInfo: TEntryInfo;
begin
  LEntryInfo.CreateInstance := ACreateInstance;
  LEntryInfo.IsWritable := AIsWritable;
  LEntryInfo._RttiType := AWriterRttiType;
  LEntryInfo.RttiName := AWriterRttiType.QualifiedName;
  LEntryInfo.GetAffinity := AGetAffinity;

  FRegistry.Add(LEntryInfo)
end;

end.
