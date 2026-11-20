# Development — Security Improvements

## 1. Limit platform admins to one group's copy in the sandbox

**Current gap:** The sandbox holds copies of every group with an open preview, and platform-admin accounts keep their roles there.

**Risk:** An admin opening one group's preview can browse other groups' copies. This matches production access but widens where that data is reachable.

**Recommended change:** Seed a preview-scoped access index that limits every account, admins included, to the requesting group, or seed one sandbox namespace per preview.

## 2. Expire sandbox copies with their preview

**Current gap:** Copies stay in the sandbox until they are refreshed or removed.

**Recommended change:** Delete a group's copy, including its Auth accounts, once it has no unexpired preview channel.
