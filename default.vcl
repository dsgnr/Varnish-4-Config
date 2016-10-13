/* SET THE HOST AND PORT OF WORDPRESS
 * *********************************************************/
vcl 4.0;
import std;

backend default {
  .host = "127.0.0.1";
  .port = "8080";
  .first_byte_timeout = 60s;
  .connect_timeout = 300s;
}
 
# SET THE ALLOWED IP OF PURGE REQUESTS
# ##########################################################
acl purge {
  "localhost";
  "127.0.0.1";
}

#THE RECV FUNCTION
# ##########################################################
sub vcl_recv {

#return(pass);

# FORWARD THE IP OF THE REQUEST
  if (req.restarts == 0) {
    if (req.http.x-forwarded-for) {
      set req.http.X-Forwarded-For =
      req.http.X-Forwarded-For + ", " + client.ip;
    } else {
      set req.http.X-Forwarded-For = client.ip;
    }
  }

# set realIP by trimming CloudFlare IP which will be used for various checks
set req.http.X-Actual-IP = regsub(req.http.X-Forwarded-For, "[, ].*$", ""); 

 # Purge request check sections for hash_always_miss, purge and ban
 # BLOCK IF NOT IP is not in purge acl
 # ##########################################################

  # Enable smart refreshing using hash_always_miss
if (req.http.Cache-Control ~ "no-cache") {
    if (client.ip ~ purge || std.ip(req.http.X-Actual-IP, "1.2.3.4") ~ purge) {
         set req.hash_always_miss = true;
    }
}

if (req.method == "PURGE") {
    if (!client.ip ~ purge || !std.ip(req.http.X-Actual-IP, "1.2.3.4") ~ purge) {
        return(synth(405,"Not allowed."));
        }
    return (purge);
  }

if (req.method == "BAN") {
        # Same ACL check as above:
        if (!client.ip ~ purge || !std.ip(req.http.X-Actual-IP, "1.2.3.4") ~ purge) {
                        return(synth(403, "Not allowed."));
        }
        ban("req.http.host == " + req.http.host +
                  " && req.url == " + req.url);

        # Throw a synthetic page so the
        # request won't go to the backend.
        return(synth(200, "Ban added"));
}

# Remove has_js and CloudFlare/Google Analytics __* cookies.
      set req.http.Cookie = regsuball(req.http.Cookie, "(^|;\s*)(_[_a-z]+|has_js)=[^;]*", "");
      # Remove a ";" prefix, if present.
     set req.http.Cookie = regsub(req.http.Cookie, "^;\s*", "");
     
 #Remove cookies for static files to avoid caching many versions of same js, especially important because we need to hash the PHPSESSID cookie
if (req.url ~ "\.(ogg|ogv|svg|svgz|eot|otf|woff2?|mp4|ttf|css|rss|atom|js|jpg|jpeg|gif|png|ico|zip|tgz|gz|rar|bz2|doc|xls|exe|ppt|tar|mid|midi|wav|bmp|rtf|cur)") {
 unset req.http.cookie;
 }

  # For Testing: If you want to test with Varnish passing (not caching) uncomment
  # return( pass );

# DO NOT CACHE RSS FEED
 if (req.url ~ "/feed(/)?") {
	return ( pass ); 
}

## Do not cache search results, comment these 3 lines if you do want to cache them

if (req.url ~ "/\?s\=") {
	return ( pass ); 
}

# CLEAN UP THE ENCODING HEADER.
  # SET TO GZIP, DEFLATE, OR REMOVE ENTIRELY.  WITH VARY ACCEPT-ENCODING
  # VARNISH WILL CREATE SEPARATE CACHES FOR EACH
  # DO NOT ACCEPT-ENCODING IMAGES, ZIPPED FILES, AUDIO, ETC.
  # ##########################################################
  if (req.http.Accept-Encoding) {
    if (req.url ~ "\.(jpg|png|gif|gz|tgz|bz2|tbz|mp3|ogg)$") {
      # No point in compressing these
      unset req.http.Accept-Encoding;
    } elsif (req.http.Accept-Encoding ~ "gzip") {
      set req.http.Accept-Encoding = "gzip";
    } elsif (req.http.Accept-Encoding ~ "deflate") {
      set req.http.Accept-Encoding = "deflate";
    } else {
      # unknown algorithm
      unset req.http.Accept-Encoding;
    }
  }

  # PIPE ALL NON-STANDARD REQUESTS
  # ##########################################################
  if (req.method != "GET" &&
    req.method != "HEAD" &&
    req.method != "PUT" && 
    req.method != "POST" &&
    req.method != "TRACE" &&
    req.method != "OPTIONS" &&
    req.method != "DELETE") {
      return (pipe);
  }
   
  # ONLY CACHE GET AND HEAD REQUESTS
  # ##########################################################
  if (req.method != "GET" && req.method != "HEAD") {
    return (pass);
  }
  
  #Do not cache logged in users
  # ##########################################################
  if ( req.http.cookie ~ "wordpress_logged_in" ) {
    return(pass);
  }
 
if (req.url ~ "wp-(login|admin|cron)|cart|core|basket|my-account|checkout|addons|administrator") {
        # Don't cache, pass to backend
        return (pass);
    }
    if ( req.url ~ "\?add-to-cart=" ) {
        return (pass);
    }

#fixed non AJAX cart|basket cache problem, may need to add wp_woocommerce_session_
if (req.http.cookie ~ "PHPSESSID|woocommerce_(session|cart)") {
return(hash);
}

#this is the problem for logging in
#if (!req.url ~ "wp-(login|admin|cron)|cart|core|basket|my-account|checkout|addons|administrator" ) { #|| !beresp.http.set-cookie ~ "woocommerce_items|wordpress_" ) {
#        # Don't cache, pass to backend
#        unset req.http.cookie;
#    }
    

 
  # IF YOU GET HERE THEN THIS REQUEST SHOULD BE CACHED
  # ##########################################################
  return (hash);
  
}

sub vcl_hash {
#this is to store cache based on PHPSESSID so cart|basket doesn't show 0
#  if (req.http.cookie) {
#    hash_data(req.http.cookie);
#  }
}

# HIT FUNCTION
# ##########################################################
sub vcl_hit {
  return (deliver);
}

# MISS FUNCTION
# ##########################################################
sub vcl_miss {
  return (fetch);
}

# FETCH FUNCTION
# ##########################################################
sub vcl_backend_response {
if (beresp.status == 403 || beresp.status == 404 || beresp.status >= 500)
    {
set beresp.uncacheable = true;
set beresp.ttl = 0s;
    }

# I SET THE VARY TO ACCEPT-ENCODING, THIS OVERRIDES W3TC 
  # TENDANCY TO SET VARY USER-AGENT.  YOU MAY OR MAY NOT WANT
  # TO DO THIS
  # ##########################################################
  set beresp.http.Vary = "Accept-Encoding";


  # IF NOT WP-ADMIN THEN UNSET COOKIES AND SET THE AMOUNT OF 
  # TIME THIS PAGE WILL STAY CACHED (TTL)
  # ##########################################################

#if (beresp.http.cookie ~ "woocommerce_") {
#set beresp.uncacheable = true;
#return (deliver);
#}  

  #may need to put the shop url here but if adding to cart|basket sends a 302 this should work
  if (!bereq.url ~ "wp-(login|admin)|cart|core|basket|administrator" && !beresp.http.set-cookie ~ "wordpress_logged_in|woocommerce_" || !beresp.status == 302 ) {
#    unset beresp.http.set-cookie;
    set beresp.ttl = 1w;
    set beresp.grace =1d;
  }

  if (beresp.ttl <= 0s ||
    beresp.http.Set-Cookie ||
    beresp.http.Vary == "*") {
      set beresp.ttl = 120 s;
      # set beresp.ttl = 120s;
      set beresp.uncacheable = true;
      return (deliver);
  }

return(deliver);

}

# DELIVER FUNCTION
# ##########################################################
sub vcl_deliver {
  # IF THIS PAGE IS ALREADY CACHED THEN RETURN A 'HIT' TEXT 
  # IN THE HEADER (GREAT FOR DEBUGGING)
  # ##########################################################
  if (obj.hits > 0) {
    set resp.http.X-Cache = "HIT";
  # IF THIS IS A MISS RETURN THAT IN THE HEADER
  # ##########################################################
  } else {
    set resp.http.X-Cache = "MISS";
  }
}
