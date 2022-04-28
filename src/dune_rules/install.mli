(** Opam install file *)
open! Stdune

module Dst : sig
  type t

  val to_string : t -> string

  include Dune_lang.Conv.S with type t := t

  val to_dyn : t -> Dyn.t
end

(** Location for installation, containing the sections relative to the current
    package, and sites of possibly other packages *)
module Section_with_site : sig
  type t =
    | Section of Dune_engine.Section.t
    | Site of
        { pkg : Dune_engine.Package.Name.t
        ; site : Dune_engine.Section.Site.t
        ; loc : Loc.t
        }

  val to_string : t -> string

  (* val parse_string : string -> (t, string) Result.t *)

  include Dune_lang.Conv.S with type t := t

  val to_dyn : t -> Dyn.t
end

module Section : sig
  type t = Dune_engine.Section.t

  include Comparable_intf.S with type key := t

  val to_string : t -> string

  val parse_string : string -> (t, string) Result.t

  val decode : t Dune_lang.Decoder.t

  val to_dyn : t -> Dyn.t

  module Paths : sig
    type section := t

    type t

    val make :
         package:Dune_engine.Package.Name.t
      -> destdir:Path.t
      -> ?libdir:Path.t
      -> ?mandir:Path.t
      -> ?docdir:Path.t
      -> ?etcdir:Path.t
      -> unit
      -> t

    val install_path : t -> section -> Dst.t -> Path.t

    val get : t -> section -> Path.t

    val get_local_location :
         Dune_engine.Context_name.t
      -> section
      -> Dune_engine.Package.Name.t
      -> Path.t
  end
end

module Entry : sig
  type 'src t = private
    { src : 'src
    ; dst : Dst.t
    ; section : Section.t
    }

  module Sourced : sig
    type source =
      | User of Loc.t
      | Dune

    type entry := Path.Build.t t

    type nonrec t =
      { source : source
      ; entry : entry
      }

    val create : ?loc:Loc.t -> entry -> t
  end

  val adjust_dst :
       src:Dune_engine.String_with_vars.t
    -> dst:string option
    -> section:Section.t
    -> Dst.t

  val make : Section.t -> ?dst:string -> Path.Build.t -> Path.Build.t t

  val make_with_site :
       Section_with_site.t
    -> ?dst:string
    -> (   loc:Loc.t
        -> pkg:Dune_engine.Package.Name.t
        -> site:Dune_engine.Section.Site.t
        -> Section.t Memo.t)
    -> Path.Build.t
    -> Path.Build.t t Memo.t

  val set_src : _ t -> 'src -> 'src t

  val relative_installed_path : _ t -> paths:Section.Paths.t -> Path.t

  val add_install_prefix :
    'a t -> paths:Section.Paths.t -> prefix:Path.t -> 'a t

  val compare : ('a -> 'a -> Ordering.t) -> 'a t -> 'a t -> Ordering.t
end

(** Same as Entry, but the destination can be in the site of a package *)
module Entry_with_site : sig
  type 'src t =
    { src : 'src
    ; dst : Dst.t
    ; section : Section_with_site.t
    }
end

module Metadata : sig
  type 'src t =
    | DefaultEntry of 'src Entry.t
    | UserDefinedEntry of 'src Entry.t
end

val gen_install_file : Path.t Entry.t list -> string

val load_install_file : Path.t -> Path.t Entry.t list