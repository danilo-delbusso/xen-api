(*
 * Copyright (c) Cloud Software Group, Inc.
 *)

open Printf
open Str
open Datamodel_types
open Dm_api
open CommonFunctions
module DT = Datamodel_types
module DU = Datamodel_utils

(*Filter out all the bits of the data model we don't want to put in the api.
  For instance we don't want the things which are marked internal only, or the
  ones marked hide_from_docs*)
let api =
  Datamodel_utils.named_self := true ;

  let obj_filter _ = true in
  let field_filter field =
    (not field.internal_only) && List.mem "closed" field.release.internal
  in
  let message_filter msg =
    Datamodel_utils.on_client_side msg
    && (not msg.msg_hide_from_docs)
    && List.mem "closed" msg.msg_release.internal
  in
  filter obj_filter field_filter message_filter
    (Datamodel_utils.add_implicit_messages ~document_order:false
       (filter obj_filter field_filter message_filter Datamodel.all_api)
    )

(*Here we extract a list of objs (look in datamodel_types.ml for the structure definitions)*)
let classes = objects_of_api api

let print_license file =
  output_string file Licence.bsd_two_clause ;
  output_string file "\n\n"

(*How shall we translate datamodel identifiers into Java, with its conventions about case, and reserved words?*)

let reserved_words = function
  | "class" ->
      "clazz"
  | "clone" ->
      "createClone"
  | "param-name" ->
      "param_name"
  | "interface" ->
      "iface"
  | "import" ->
      "import_"
  | s ->
      s

(* Given a XenAPI on-the-wire representation of an enum value, return the Java enum *)
let enum_of_wire x =
  global_replace (regexp_string "-") "_" (String.uppercase_ascii x)

let second_character_is_uppercase s =
  if String.length s < 2 then
    false
  else
    let second_char = String.sub s 1 1 in
    second_char = String.uppercase_ascii second_char

let transform s =
  if second_character_is_uppercase s then
    s
  else
    String.capitalize_ascii (reserved_words (String.uncapitalize_ascii s))

let class_case x =
  String.concat "" (List.map transform (Astring.String.cuts ~sep:"_" x))

let keywords = [("public", "_public")]

let keyword_map s =
  if List.mem_assoc s keywords then List.assoc s keywords else s

let camel_case s =
  let ss = Astring.String.cuts ~sep:"_" s |> List.map transform in
  let result =
    match ss with
    | [] ->
        ""
    | h :: tl ->
        let h' =
          if String.length h > 1 then
            let sndchar = String.sub h 1 1 in
            if sndchar = String.uppercase_ascii sndchar then
              h
            else
              String.uncapitalize_ascii h
          else
            String.uncapitalize_ascii h
        in
        h' ^ String.concat "" tl
  in
  keyword_map result

let exception_class_case x =
  String.concat ""
    (List.map
       (fun s -> String.capitalize_ascii (String.lowercase_ascii s))
       (Astring.String.cuts ~sep:"_" x)
    )

(*As we process the datamodel, we collect information about enumerations, types*)
(* and records, which we use to create Types.java later *)

let enums = Hashtbl.create 10

let records = Hashtbl.create 10

(*We want an empty mutable set to keep the types in.*)
module Ty = struct
  type t = DT.ty

  let compare = compare
end

module TypeSet = Set.Make (Ty)

let types = ref TypeSet.empty

(* Helper functions for types *)
let rec get_java_type ty =
  types := TypeSet.add ty !types ;
  match ty with
  | SecretString | String ->
      "String"
  | Int ->
      "Long"
  | Float ->
      "Double"
  | Bool ->
      "Boolean"
  | DateTime ->
      "Date"
  | Enum (name, ls) ->
      Hashtbl.replace enums name ls ;
      sprintf "Types.%s" (class_case name)
  | Set t1 ->
      sprintf "Set<%s>" (get_java_type t1)
  | Map (t1, t2) ->
      sprintf "Map<%s, %s>" (get_java_type t1) (get_java_type t2)
  | Ref x ->
      class_case x (* We want to hide all refs *)
  | Record x ->
      sprintf "%s.Record" (class_case x)
  | Option x ->
      get_java_type x

(*We'd like the list of XenAPI objects to appear as an enumeration so we can*)
(* switch on them, so add it using this mechanism*)
let switch_enum =
  Enum ("XenAPIObjects", List.map (fun x -> (x.name, x.description)) classes)

(*Helper function for get_marshall_function*)
let rec get_marshall_function_rec = function
  | SecretString | String ->
      "String"
  | Int ->
      "Long"
  | Float ->
      "Double"
  | Bool ->
      "Boolean"
  | DateTime ->
      "Date"
  | Enum (name, _) ->
      class_case name
  | Set t1 ->
      sprintf "SetOf%s" (get_marshall_function_rec t1)
  | Map (t1, t2) ->
      sprintf "MapOf%s%s"
        (get_marshall_function_rec t1)
        (get_marshall_function_rec t2)
  | Ref ty ->
      class_case ty (* We want to hide all refs *)
  | Record ty ->
      sprintf "%sRecord" (class_case ty)
  | Option ty ->
      get_marshall_function_rec ty

(*get_marshall_function (Set(Map(Float,Bool)));; -> "toSetOfMapOfDoubleBoolean"*)
let get_marshall_function ty = "to" ^ get_marshall_function_rec ty

let _ = get_java_type switch_enum

(* Generate the methods *)

let get_java_type_or_void = function
  | None ->
      "void"
  | Some (ty, _) ->
      get_java_type ty

(* Here are a lot of functions which ask questions of the messages associated with*)
(* objects, the answers to which are helpful when generating the corresponding java*)
(* functions. For instance is_method_static takes an object's message, and*)
(* determines whether it should be static or not in java, by looking at whether*)
(* it has a self parameter or not.*)

(*Similar functions for deprecation of methods*)

let get_method_deprecated_release_name message =
  match message.msg_release.internal_deprecated_since with
  | Some version ->
      Some (get_release_branding version)
  | None ->
      None

let get_method_deprecated_annotation message =
  match get_method_deprecated_release_name message with
  | Some version ->
      {|@Deprecated(since = "|} ^ version ^ {|")|}
  | None ->
      ""

let get_method_param {param_type= ty; param_name= name; _} =
  let ty = get_java_type ty in
  let name = camel_case name in
  sprintf "%s %s" ty name

let get_method_params_for_signature params =
  String.concat ", " ("Connection c" :: List.map get_method_param params)

let get_method_params_for_xml message params =
  let f = function
    | {param_type= Record _; param_name= name; _} ->
        camel_case name ^ "_map"
    | {param_name= name; _} ->
        camel_case name
  in
  match params with
  | [] ->
      if is_method_static message then
        []
      else
        ["this.ref"]
  | _ ->
      if is_method_static message then
        List.map f params
      else
        "this.ref" :: List.map f params

(* Here is the main method generating function.*)
let gen_method file cls message params async_version =
  let return_type =
    if
      String.lowercase_ascii cls.name = "event"
      && String.lowercase_ascii message.msg_name = "from"
    then
      "EventBatch"
    else
      get_java_type_or_void message.msg_result
  in
  let method_static = if is_method_static message then "static " else "" in
  let method_name = camel_case message.msg_name in
  let paramString = get_method_params_for_signature params in
  let default_errors =
    [
      ( "BadServerResponse"
      , "Thrown if the response from the server contains an invalid status."
      )
    ; ("XenAPIException", "if the call failed.")
    ; ( "IOException"
      , "if an error occurs during a send or receive. This includes cases \
         where a payload is invalid JSON."
      )
    ]
  in
  let publishInfo = get_published_info_message message cls in

  fprintf file "    /**\n" ;
  fprintf file "     * %s\n" (escape_xml message.msg_doc) ;
  fprintf file "     * Minimum allowed role: %s\n"
    (get_minimum_allowed_role message) ;
  if not (publishInfo = "") then fprintf file "     * %s\n" publishInfo ;
  let deprecated_info =
    match get_method_deprecated_release_name message with
    | Some version ->
        "     * @deprecated since " ^ version ^ "\n"
    | None ->
        ""
  in
  fprintf file "%s" deprecated_info ;
  fprintf file "     *\n" ;
  fprintf file "     * @param c The connection the call is made on\n" ;

  List.iter
    (fun x ->
      let paramPublishInfo = get_published_info_param message x in
      fprintf file "     * @param %s %s%s\n" (camel_case x.param_name)
        (if x.param_doc = "" then "No description" else escape_xml x.param_doc)
        (if paramPublishInfo = "" then "" else " " ^ paramPublishInfo)
    )
    params ;

  ( if async_version then
      fprintf file "     * @return Task\n"
    else
      match message.msg_result with
      | None ->
          ()
      | Some (_, "") ->
          fprintf file "     * @return %s\n"
            (get_java_type_or_void message.msg_result)
      | Some (_, desc) ->
          fprintf file "     * @return %s\n" desc
  ) ;

  List.iter
    (fun x -> fprintf file "     * @throws %s %s\n" (fst x) (snd x))
    default_errors ;
  List.iter
    (fun x ->
      fprintf file "     * @throws Types.%s %s\n"
        (exception_class_case x.err_name)
        x.err_doc
    )
    message.msg_errors ;

  fprintf file "    */\n" ;

  let deprecated_string =
    match get_method_deprecated_annotation message with
    | "" ->
        ""
    | other ->
        "    " ^ other ^ "\n"
  in
  if async_version then
    fprintf file "%s    public %sTask %sAsync(%s) throws\n" deprecated_string
      method_static method_name paramString
  else
    fprintf file "%s    public %s%s %s(%s) throws\n" deprecated_string
      method_static return_type method_name paramString ;

  let all_errors =
    List.map fst default_errors
    @ List.map
        (fun x -> "Types." ^ exception_class_case x.err_name)
        message.msg_errors
  in
  fprintf file "       %s {\n" (String.concat ",\n       " all_errors) ;

  if async_version then
    fprintf file "        String methodCall = \"Async.%s.%s\";\n"
      message.msg_obj_name message.msg_name
  else
    fprintf file "        String methodCall = \"%s.%s\";\n" message.msg_obj_name
      message.msg_name ;

  if message.msg_session then
    fprintf file "        String sessionReference = c.getSessionReference();\n"
  else
    () ;

  let record_params =
    List.filter
      (function {param_type= Record _; _} -> true | _ -> false)
      message.msg_params
  in

  List.iter
    (fun {param_name= s; _} ->
      let name = camel_case s in
      fprintf file "        var %s_map = %s.toMap();\n" name name
    )
    record_params ;

  fprintf file "        Object[] methodParameters = {" ;

  let methodParamsList =
    if message.msg_session then
      "sessionReference" :: get_method_params_for_xml message params
    else
      get_method_params_for_xml message params
  in

  output_string file (String.concat ", " methodParamsList) ;

  fprintf file "};\n" ;

  if message.msg_result != None || async_version then
    fprintf file "        var typeReference = new TypeReference<%s>(){};\n"
      (if async_version then "Task" else return_type) ;

  let last_statement =
    match message.msg_result with
    | None when not async_version ->
        "        c.dispatch(methodCall, methodParameters);\n"
    | _ ->
        "        return c.dispatch(methodCall, methodParameters, typeReference);\n"
  in
  fprintf file "%s" last_statement ;

  fprintf file "    }\n\n"

(*Some methods have an almost identical asynchronous counterpart, which returns*)
(* a Task reference rather than its usual return value*)
let gen_method_and_asynchronous_counterpart file cls message =
  let generator x =
    if message.msg_async then gen_method file cls message x true ;
    gen_method file cls message x false
  in
  match message.msg_params with
  | [] ->
      generator []
  | _ ->
      let paramGroups = gen_param_groups message message.msg_params in
      List.iter generator paramGroups

(* Generate the record *)

(* The fields of an object are stored in trees in the datamodel, which means that*)
(* the next three functions, which are conceptually for generating the fields*)
(* of each class, and for the corresponding entries in the toString and toMap*)
(* functions are in fact implemented as three sets of three mutual recursions,*)
(* which take the trees apart. *)

let gen_record_field file prefix field cls =
  let ty = get_java_type field.ty in
  let full_name = String.concat "_" (List.rev (field.field_name :: prefix)) in
  let name = camel_case full_name in
  let publishInfo = get_published_info_field field cls in
  fprintf file "        /**\n" ;
  fprintf file "         * %s\n" (escape_xml field.field_description) ;
  if not (publishInfo = "") then fprintf file "         * %s\n" publishInfo ;
  fprintf file "         */\n" ;
  fprintf file "        @JsonProperty(\"%s\")\n" full_name ;

  if field.lifecycle.state = Lifecycle.Deprecated_s then
    fprintf file "        @Deprecated(since  = \"%s\")\n"
      (get_release_branding (get_deprecated_release field.lifecycle.transitions)) ;

  fprintf file "        public %s %s;\n\n" ty name

let rec gen_record_namespace file prefix (name, contents) cls =
  List.iter (gen_record_contents file (name :: prefix) cls) contents

and gen_record_contents file prefix cls = function
  | Field f ->
      gen_record_field file prefix f cls
  | Namespace (n, cs) ->
      gen_record_namespace file prefix (n, cs) cls

(***)

let gen_record_tostring_field file prefix field =
  let name = String.concat "_" (List.rev (field.field_name :: prefix)) in
  let name = camel_case name in
  fprintf file
    "            print.printf(\"%%1$20s: %%2$s\\n\", \"%s\", this.%s);\n" name
    name

let rec gen_record_tostring_namespace file prefix (name, contents) =
  List.iter (gen_record_tostring_contents file (name :: prefix)) contents

and gen_record_tostring_contents file prefix = function
  | Field f ->
      gen_record_tostring_field file prefix f
  | Namespace (n, cs) ->
      gen_record_tostring_namespace file prefix (n, cs)

(***)

let field_default = function
  | SecretString | String ->
      {|""|}
  | Int ->
      "0"
  | Float ->
      "0.0"
  | Bool ->
      "false"
  | DateTime ->
      "new Date(0)"
  | Enum ("vif_locking_mode", _) ->
      "Types.VifLockingMode.NETWORK_DEFAULT" (* XOP-372 *)
  | Enum (name, _) ->
      sprintf "Types.%s.UNRECOGNIZED" (class_case name)
  | Set t1 ->
      sprintf "new LinkedHashSet<%s>()" (get_java_type t1)
  | Map (t1, t2) ->
      sprintf "new HashMap<%s, %s>()" (get_java_type t1) (get_java_type t2)
  | Ref ty ->
      sprintf {|new %s("OpaqueRef:NULL")|} (class_case ty)
  | Record _ ->
      assert false
  | Option _ ->
      "null"

let gen_record_tomap_field file prefix field =
  let name = String.concat "_" (List.rev (field.field_name :: prefix)) in
  let name' = camel_case name in
  let default = field_default field.ty in
  fprintf file "            map.put(\"%s\", this.%s == null ? %s : this.%s);\n"
    name name' default name'

let rec gen_record_tomap_contents file prefix = function
  | Field f ->
      gen_record_tomap_field file prefix f
  | Namespace (n, cs) ->
      List.iter (gen_record_tomap_contents file (n :: prefix)) cs

(*Generate the Record subclass for the given class, with its toString and toMap*)
(* methods. We're also modifying the records hash table as a side effect*)

let gen_record file cls =
  let class_name = class_case cls.name in
  let _ = Hashtbl.replace records cls.name cls.contents in
  let contents = cls.contents in
  fprintf file "    /**\n" ;
  fprintf file "     * Represents all the fields in a %s\n" class_name ;
  fprintf file "     */\n" ;
  fprintf file "    public static class Record implements Types.Record {\n" ;
  fprintf file "        public String toString() {\n" ;
  fprintf file "            StringWriter writer = new StringWriter();\n" ;
  fprintf file "            PrintWriter print = new PrintWriter(writer);\n" ;

  List.iter (gen_record_tostring_contents file []) contents ;
  (*for the Event.Record, we have to add in the snapshot field by hand, because it's not in the data model!*)
  if cls.name = "event" then
    fprintf file
      "            print.printf(\"%%1$20s: %%2$s\\n\", \"snapshot\", \
       this.snapshot);\n" ;

  fprintf file "            return writer.toString();\n" ;
  fprintf file "        }\n\n" ;
  fprintf file "        /**\n" ;
  fprintf file "         * Convert a %s.Record to a Map\n" cls.name ;
  fprintf file "         */\n" ;
  fprintf file "        public Map<String,Object> toMap() {\n" ;
  fprintf file "            var map = new HashMap<String,Object>();\n" ;

  List.iter (gen_record_tomap_contents file []) contents ;
  if cls.name = "event" then
    fprintf file "            map.put(\"snapshot\", this.snapshot);\n" ;

  fprintf file "            return map;\n" ;
  fprintf file "        }\n\n" ;

  List.iter (gen_record_contents file [] cls) contents ;
  if cls.name = "event" then (
    fprintf file "        /**\n" ;
    fprintf file
      "         * The record of the database object that was added, changed or \
       deleted\n" ;
    fprintf file
      "         * (the actual type will be VM.Record, VBD.Record or similar)\n" ;
    fprintf file "         */\n" ;
    fprintf file "        public Object snapshot;\n"
  ) ;

  fprintf file "    }\n\n"

(* Generate the class *)

let class_is_empty cls = cls.contents = []

let gen_class cls folder =
  let class_name = class_case cls.name in
  let methods = cls.messages in
  let file = open_out (Filename.concat folder class_name ^ ".java") in
  let publishInfo = get_published_info_class cls in
  print_license file ;
  fprintf file
    {|package com.xensource.xenapi;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.core.type.TypeReference;
import com.xensource.xenapi.Types.BadServerResponse;
import com.xensource.xenapi.Types.XenAPIException;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.util.*;
import java.io.IOException;

|} ;
  fprintf file "/**\n" ;
  fprintf file " * %s\n" cls.description ;
  if not (publishInfo = "") then fprintf file " * %s\n" publishInfo ;
  fprintf file " *\n" ;
  fprintf file " * @author Cloud Software Group, Inc.\n" ;
  fprintf file " */\n" ;
  fprintf file "public class %s extends XenAPIObject {\n\n" class_name ;

  if class_is_empty cls then
    fprintf file
      "\n    public String toWireString() {\n        return null;\n    }\n\n"
  else (
    fprintf file "    /**\n" ;
    fprintf file "     * The XenAPI reference (OpaqueRef) to this object.\n" ;
    fprintf file "     */\n" ;
    fprintf file "    protected final String ref;\n\n" ;
    fprintf file "    /**\n" ;
    fprintf file "     * For internal use only.\n" ;
    fprintf file "     */\n" ;
    fprintf file "    %s(String ref) {\n" class_name ;
    fprintf file "       this.ref = ref;\n" ;
    fprintf file "    }\n\n" ;
    fprintf file "    /**\n" ;
    fprintf file
      "     * @return The XenAPI reference (OpaqueRef) to this object.\n" ;
    fprintf file "     */\n" ;
    fprintf file "    public String toWireString() {\n" ;
    fprintf file "       return this.ref;\n" ;
    fprintf file "    }\n\n"
  ) ;

  if not (class_is_empty cls) then (
    fprintf file "    /**\n" ;
    fprintf file
      "     * If obj is a %s, compares XenAPI references for equality.\n"
      class_name ;
    fprintf file "     */\n" ;
    fprintf file "    @Override\n" ;
    fprintf file "    public boolean equals(Object obj)\n" ;
    fprintf file "    {\n" ;
    fprintf file "        if (obj instanceof %s)\n" class_name ;
    fprintf file "        {\n" ;
    fprintf file "            %s other = (%s) obj;\n" class_name class_name ;
    fprintf file "            return other.ref.equals(this.ref);\n" ;
    fprintf file "        } else\n" ;
    fprintf file "        {\n" ;
    fprintf file "            return false;\n" ;
    fprintf file "        }\n" ;
    fprintf file "    }\n\n" ;

    (*hashcode*)
    fprintf file "    @Override\n" ;
    fprintf file "    public int hashCode()\n" ;
    fprintf file "    {\n" ;
    fprintf file "        return ref.hashCode();\n" ;
    fprintf file "    }\n\n" ;
    flush file ;
    gen_record file cls ;
    flush file
  ) ;

  List.iter (gen_method_and_asynchronous_counterpart file cls) methods ;

  flush file ;
  fprintf file "}" ;
  close_out file

(**?*)
(* Generate Marshalling Class *)

(*This generates the special case code for marshalling the snapshot field in an Event.Record*)

let generate_snapshot_hack =
  {|
       Object a,b;
       a = map.get("snapshot");
       switch(|}
  ^ get_marshall_function switch_enum
  ^ {|(record.clazz)){
|}
  ^ String.concat "\n"
      (List.map
         (fun x ->
           "        case "
           ^ String.uppercase_ascii x
           ^ ": b = "
           ^ get_marshall_function (Record x)
           ^ "(a); break;"
         )
         (List.map
            (fun x -> x.name)
            (List.filter (fun x -> not (class_is_empty x)) classes)
         )
      )
  ^ {|
        default: 
           throw new RuntimeException("Internal error in auto-generated code whilst unmarshalling event snapshot");
      }
      record.snapshot = b;|}

let gen_marshall_record_field prefix field =
  let ty = get_marshall_function field.ty in
  let name = String.concat "_" (List.rev (field.field_name :: prefix)) in
  let name' = camel_case name in
  "        record." ^ name ^ " = " ^ ty ^ "(map.get(\"" ^ name' ^ "\"));\n"

let rec gen_marshall_record_namespace prefix (name, contents) =
  String.concat "\n"
    (List.map (gen_marshall_record_contents (name :: prefix)) contents)

and gen_marshall_record_contents prefix = function
  | Field f ->
      gen_marshall_record_field prefix f
  | Namespace (n, cs) ->
      gen_marshall_record_namespace prefix (n, cs)

(*don't generate for complicated types. They're not needed.*)

let rec gen_marshall_body = function
  | SecretString | String ->
      "return (String) object;\n"
  | Int ->
      "return Long.valueOf((String) object);\n"
  | Float ->
      "return (Double) object;\n"
  | Bool ->
      "return (Boolean) object;\n"
  | DateTime ->
      {|
      try {
        return (Date) object;
    } catch (ClassCastException e){
        //Occasionally the date comes back as an ocaml float rather than
        //in the xmlrpc format! Catch this and convert.
        return (new Date((long) (1000*Double.parseDouble((String) object))));
    }|}
  | Ref ty ->
      "return new" ^ class_case ty ^ "((String) object);\n"
  | Enum (name, _) ->
      {|try {
            return |}
      ^ class_case name
      ^ {|.valueOf(((String) object).toUpperCase().replace('-','_'));
        } catch (IllegalArgumentException ex) { 
            return |}
      ^ class_case name
      ^ {|.UNRECOGNIZED;
        }|}
  | Set ty ->
      let ty_name = get_java_type ty in
      let marshall_fn = get_marshall_function ty in
      {|Object[] items = (Object[]) object;
        Set<|}
      ^ ty_name
      ^ {|> result = new LinkedHashSet<>(); 
        for(Object item: items) {
          |}
      ^ ty_name
      ^ {| typed = |}
      ^ marshall_fn
      ^ {|(item); 
          result.add(typed);
        }
        return result;|}
  | Map (ty, ty') ->
      let ty_name = get_java_type ty in
      let ty_name' = get_java_type ty' in
      let marshall_fn = get_marshall_function ty in
      let marshall_fn' = get_marshall_function ty' in
      {|var map = (Map<Object, Object>)object;
        var result = new HashMap<|}
      ^ ty_name
      ^ {|,|}
      ^ ty_name'
      ^ {|>(); 
        for(var entry: map.entrySet()) {
          var key = |}
      ^ marshall_fn
      ^ {|(entry.getKey());
          var value = |}
      ^ marshall_fn'
      ^ {|(entry.getValue());
          result.put(key, value);
        }
        return result;|}
  | Record ty ->
      let contents = Hashtbl.find records ty in
      let cls_name = class_case ty in
      {|Map<String,Object> map = (Map<String,Object>) object;|}
      ^ cls_name
      ^ {|.Record record = new |}
      ^ cls_name
      ^ {| .Record(); |}
      ^ String.concat "" (List.map (gen_marshall_record_contents []) contents)
      ^
      (*Event.Record needs a special case to handle snapshots*)
      if ty = "event" then
        generate_snapshot_hack
      else
        "        return record;"
  | Option ty ->
      gen_marshall_body ty

let gen_error_field_name field =
  camel_case (String.concat "_" (Astring.String.cuts ~sep:" " field))

(* Now run it *)

let populate_releases templdir class_dir =
  render_file
    ("APIVersion.mustache", "APIVersion.java")
    json_releases templdir class_dir

let populate_types templdir class_dir =
  let list_errors =
    Hashtbl.fold (fun k v acc -> (k, v) :: acc) Datamodel.errors []
  in
  let errors =
    List.map
      (fun (_, error) ->
        let class_name = exception_class_case error.err_name in
        let err_params =
          List.mapi
            (fun index value ->
              `O
                [
                  ("name", `String (gen_error_field_name value))
                ; ("index", `Float (Int.to_float index))
                ; ("last", `Bool (index == List.length error.err_params - 1))
                ]
            )
            error.err_params
        in
        `O
          [
            ("description", `String (escape_xml error.err_doc))
          ; ("class_name", `String class_name)
          ; ("err_params", `A err_params)
          ]
      )
      list_errors
  in
  let list_enums = Hashtbl.fold (fun k v acc -> (k, v) :: acc) enums [] in
  let enums =
    List.map
      (fun (enum_name, enum_values) ->
        let class_name = class_case enum_name in
        let mapped_values =
          List.map
            (fun (name, description) ->
              let escaped_description =
                global_replace (regexp_string "*/") "* /" description
              in
              let final_description =
                global_replace (regexp_string "\n") "\n         * "
                  escaped_description
              in
              `O
                [
                  ("name", `String name)
                ; ("name_uppercase", `String (enum_of_wire name))
                ; ("description", `String final_description)
                ]
            )
            enum_values
        in
        `O [("class_name", `String class_name); ("values", `A mapped_values)]
      )
      list_enums
  in
  let list_types = TypeSet.fold (fun t acc -> t :: acc) !types [] in
  let types =
    List.map
      (fun t ->
        let type_string = get_java_type t in
        let class_name = class_case type_string in
        let method_name = get_marshall_function t in
        (*Every type which may be returned by a function may also be the result of the*)
        (* corresponding asynchronous task. We therefore need to generate corresponding*)
        (* marshalling functions which can take the raw xml of the tasks result field*)
        (* and turn it into the corresponding type. Luckily, the only things returned by*)
        (* asynchronous tasks are object references and strings, so rather than implementing*)
        (* the general recursive structure we'll just make one for each of the classes*)
        (* that's been registered as a marshall-needing type*)
        let generate_reference_task_result_func =
          match t with Ref _ -> true | _ -> false
        in
        `O
          [
            ("name", `String type_string)
          ; ("class_name", `String class_name)
          ; ("method_name", `String method_name)
          ; ( "suppress_unchecked_warning"
            , `Bool (match t with Map _ | Record _ -> true | _ -> false)
            )
          ; ( "generate_reference_task_result_func"
            , `Bool generate_reference_task_result_func
            )
          ; ("method_body", `String (gen_marshall_body t))
          ]
      )
      list_types
  in
  let json =
    `O [("errors", `A errors); ("enums", `A enums); ("types", `A types)]
  in
  render_file ("Types.mustache", "Types.java") json templdir class_dir

let _ =
  let templdir = "templates" in
  let class_dir = "autogen/xen-api/src/main/java/com/xensource/xenapi" in
  List.iter (fun x -> gen_class x class_dir) classes ;
  populate_releases templdir class_dir ;
  populate_types templdir class_dir ;

  let uncommented_license = string_of_file "LICENSE" in
  let class_license = open_out "autogen/xen-api/src/main/resources/LICENSE" in
  output_string class_license uncommented_license
