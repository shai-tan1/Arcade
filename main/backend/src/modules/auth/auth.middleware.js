import jwt from 'jsonwebtoken';
import { JWT_SECRET_KEY } from '../../shared/constants/index.js';

export const auth = async (req, res, next) => {
    const token = req.cookies?.token;
    
    try {
        if (!token) {
            // console.log('Auth: No token provided');
            return res.status(403).json({ message: 'No access' });
        }
        // console.log('Auth: Checking token', { token: token ? 'present' : 'missing' });
        const decoded = jwt.verify(token, JWT_SECRET_KEY);
        // console.log('Auth: User authenticated', { userId: decoded._id });
        req.userId = decoded;
        next();
    } catch (error) {
        // console.log('Auth: Invalid token:', error.message);
        return res.status(403).json({ message: 'No access' });
    }
};